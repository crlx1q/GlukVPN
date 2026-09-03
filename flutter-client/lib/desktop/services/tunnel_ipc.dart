import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Low-level named-pipe transport to the privileged tunnel service.
///
/// Everything here is blocking Win32, so each transaction is executed inside
/// `Isolate.run` and never touches the UI thread.
///
/// Wire format: one UTF-8 JSON object per line, request and response. The
/// pipe is opened in message mode, but we still delimit with newlines so the
/// protocol survives byte-mode fallbacks.


/// Bumped whenever the request/response shape changes incompatibly.
///
/// 2: "up" carries the sing-box gateway, plus the flat split keys the service
///    has always read. Must stay in lockstep with kProtocolVersion in
///    native/glukvpn-tunnel-service/src/pipe_server.h - the app and the
///    service ship in the same installer, and a mismatch is reported rather
///    than guessed at.
const int kTunnelProtocolVersion = 2;

const int _errorFileNotFound = 2;
const int _errorAccessDenied = 5;
const int _errorPipeBusy = 231;
const int _errorSemTimeout = 121;

/// Raw result of a pipe round-trip.
class PipeReply {
  const PipeReply.ok(this.payload)
      : errorCode = null,
        errorMessage = null;

  const PipeReply.failure(this.errorCode, this.errorMessage) : payload = null;

  final Map<String, dynamic>? payload;
  final String? errorCode;
  final String? errorMessage;

  bool get ok => errorCode == null && payload != null;
}

/// Arguments bundle for the isolate entry point.
class _PipeCall {
  const _PipeCall(this.pipeName, this.request, this.timeoutMs);

  final String pipeName;
  final String request;
  final int timeoutMs;
}

/// Result bundle returned from the isolate.
class _PipeOutcome {
  const _PipeOutcome(this.text, this.errorCode, this.errorMessage);

  final String? text;
  final String? errorCode;
  final String? errorMessage;
}

/// Performs one blocking connect / write / read / close cycle.
///
/// Must stay a top-level function so it can be sent to a fresh isolate.
_PipeOutcome _pipeTransact(_PipeCall call) {
  final fullName = r'\\.\pipe\' + call.pipeName;
  final namePtr = fullName.toNativeUtf16();

  int handle = INVALID_HANDLE_VALUE;
  try {
    // Try a few times: the service may be mid-restart, or all instances busy.
    final deadline = DateTime.now().add(Duration(milliseconds: call.timeoutMs));
    while (true) {
      handle = CreateFile(
        namePtr,
        GENERIC_READ | GENERIC_WRITE,
        0,
        nullptr,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        NULL,
      );
      if (handle != INVALID_HANDLE_VALUE) break;

      final err = GetLastError();
      if (err == _errorFileNotFound) {
        return const _PipeOutcome(
          null,
          'service_unavailable',
          'GlukVPN tunnel service is not running.',
        );
      }
      if (err == _errorAccessDenied) {
        return const _PipeOutcome(
          null,
          'pipe_denied',
          'Access to the tunnel service was denied.',
        );
      }
      if (err != _errorPipeBusy) {
        return _PipeOutcome(
          null,
          'pipe_unavailable',
          'CreateFile failed with error $err.',
        );
      }
      if (DateTime.now().isAfter(deadline)) {
        return const _PipeOutcome(
          null,
          'pipe_timeout',
          'All tunnel service pipe instances are busy.',
        );
      }
      // All instances busy: wait for one to free up.
      Sleep(250);
    }

    // Switch to message mode; harmless if the server created a byte pipe.
    final modePtr = calloc<Uint32>()..value = PIPE_READMODE_MESSAGE;
    try {
      SetNamedPipeHandleState(handle, modePtr, nullptr, nullptr);
    } finally {
      calloc.free(modePtr);
    }

    // ---- write request ----
    final requestBytes = utf8.encode(call.request + '\n');
    final writeBuf = calloc<Uint8>(requestBytes.length);
    final written = calloc<Uint32>();
    try {
      writeBuf.asTypedList(requestBytes.length).setAll(0, requestBytes);
      final okWrite =
          WriteFile(handle, writeBuf, requestBytes.length, written, nullptr);
      if (okWrite == 0) {
        return _PipeOutcome(
          null,
          'pipe_write_failed',
          'WriteFile failed with error ${GetLastError()}.',
        );
      }
    } finally {
      calloc.free(writeBuf);
      calloc.free(written);
    }

    // ---- read response ----
    const chunkSize = 16 * 1024;
    final readBuf = calloc<Uint8>(chunkSize);
    final read = calloc<Uint32>();
    final sink = BytesBuilder(copy: false);
    try {
      while (true) {
        final okRead = ReadFile(handle, readBuf, chunkSize, read, nullptr);
        final count = read.value;

        if (okRead == 0) {
          final err = GetLastError();
          // ERROR_MORE_DATA just means the message is longer than our chunk.
          if (err == ERROR_MORE_DATA) {
            sink.add(readBuf.asTypedList(count).toList(growable: false));
            continue;
          }
          if (err == _errorSemTimeout) {
            return const _PipeOutcome(
              null,
              'pipe_timeout',
              'Timed out waiting for the tunnel service.',
            );
          }
          if (sink.isNotEmpty) break; // server closed after a full reply
          return _PipeOutcome(
            null,
            'pipe_read_failed',
            'ReadFile failed with error $err.',
          );
        }

        if (count == 0) break;
        final bytes = readBuf.asTypedList(count).toList(growable: false);
        sink.add(bytes);

        // A newline terminates the reply.
        if (bytes.contains(0x0A)) break;
      }
    } finally {
      calloc.free(readBuf);
      calloc.free(read);
    }

    final raw = sink.takeBytes();
    if (raw.isEmpty) {
      return const _PipeOutcome(
        null,
        'pipe_empty_response',
        'The tunnel service returned nothing.',
      );
    }

    return _PipeOutcome(utf8.decode(raw, allowMalformed: true).trim(), null, null);
  } finally {
    if (handle != INVALID_HANDLE_VALUE) {
      CloseHandle(handle);
    }
    calloc.free(namePtr);
  }
}

/// Thin async wrapper around [_pipeTransact].
class TunnelPipe {
  TunnelPipe({
    this.pipeName = 'GlukVPN.tunnel',
    this.timeout = const Duration(seconds: 12),
  });

  final String pipeName;
  final Duration timeout;

  /// Sends [request] and decodes the JSON reply.
  ///
  /// Never throws for transport problems — they come back as a failed
  /// [PipeReply] so callers can map them onto a connection phase.
  Future<PipeReply> send(Map<String, dynamic> request) async {
    final encoded = jsonEncode(request);
    final call = _PipeCall(pipeName, encoded, timeout.inMilliseconds);

    _PipeOutcome outcome;
    try {
      outcome = await Isolate.run<_PipeOutcome>(() => _pipeTransact(call))
          .timeout(timeout + const Duration(seconds: 3));
    } catch (e) {
      return PipeReply.failure('pipe_timeout', e.toString());
    }

    if (outcome.errorCode != null) {
      return PipeReply.failure(outcome.errorCode!, outcome.errorMessage);
    }

    final text = outcome.text;
    if (text == null || text.isEmpty) {
      return const PipeReply.failure(
        'pipe_empty_response',
        'Empty reply from the tunnel service.',
      );
    }

    // Defensive: take the first line only.
    final firstLine = const LineSplitter()
        .convert(text)
        .firstWhere((String l) => l.trim().isNotEmpty, orElse: () => '');
    if (firstLine.isEmpty) {
      return const PipeReply.failure(
        'pipe_empty_response',
        'Empty reply from the tunnel service.',
      );
    }

    try {
      final decoded = jsonDecode(firstLine);
      if (decoded is! Map<String, dynamic>) {
        return const PipeReply.failure(
          'pipe_bad_response',
          'The tunnel service sent a malformed reply.',
        );
      }
      return PipeReply.ok(decoded);
    } catch (e) {
      return PipeReply.failure('pipe_bad_response', e.toString());
    }
  }
}

