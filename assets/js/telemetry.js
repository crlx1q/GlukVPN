/* ==========================================================================
   GlukVPN: глобальный сбор клиентских ошибок сайта.

   Ловит всё, что не поймали сами: window.onerror и необработанные промисы.
   Отчёт уходит на POST /api/telemetry/error того же контрол-сервера, что и
   вход, и виден в админке во вкладке Client Bug Logs.

   Что здесь НЕ делается осознанно:
     - не отправляются токены, поля форм и содержимое страницы: только имя
       ошибки, сообщение, стек и путь страницы;
     - телеметрия никогда не мешает странице - любая её собственная ошибка
       глотается молча, иначе один сбой превращается в цикл отчётов.
   ========================================================================== */
(function () {
  "use strict";

  var CFG = window.GLUK_CONFIG || {};
  var API = CFG.api || {};
  var VERSION = (CFG.release || {}).version || "site";

  function trimBase(url) {
    return String(url || "").replace(/\/+$/, "");
  }

  /* Тот же выбор канала, что в auth.js и register.js: приходит имя канала, а
     не адрес, и оно проверяется по своему же списку API.base. Параметром в
     URL нельзя увести отчёты на чужой сервер. */
  function pickChannel() {
    var fallback = API.channel === "prod" ? "prod" : "beta";
    var bases = API.base || {};
    var m = /[?&]api=([^&]*)/.exec(location.search || "");
    var wanted = m ? decodeURIComponent(m[1]).toLowerCase() : "";
    if (!wanted) {
      try {
        wanted = sessionStorage.getItem("gluk.api") || "";
      } catch (e) {
        wanted = "";
      }
    }
    return wanted && bases[wanted] ? wanted : fallback;
  }

  var BASE = trimBase((API.base || {})[pickChannel()]);

  /* Ограничения на стороне клиента. Сервер режет поток и сам, но незачем
     отправлять то, что всё равно будет отброшено: сломанный рендер умеет
     выбрасывать одну и ту же ошибку сотни раз в секунду. */
  var MAX_PER_PAGE = 8;
  var DEDUPE_MS = 60000;
  var sent = 0;
  var seen = {};

  function allow(key) {
    if (!BASE || sent >= MAX_PER_PAGE) return false;
    var now = Date.now();
    if (seen[key] && now - seen[key] < DEDUPE_MS) return false;
    seen[key] = now;
    sent += 1;
    return true;
  }

  /* Где именно произошло: путь страницы, плюс уточнение от вызывающего кода
     («освобождение слота», «загрузка тарифов» и т. п.). */
  function where(extra) {
    var page = location.pathname + (location.hash || "");
    return extra ? page + " \u00b7 " + extra : page;
  }

  function describe(error) {
    if (error && typeof error === "object") {
      return {
        name: String(error.name || "Error"),
        message: String(error.message || error.reason || "(no message)"),
        stack: error.stack ? String(error.stack) : null,
      };
    }
    return { name: "Error", message: String(error), stack: null };
  }

  /**
   * Отправляет один отчёт. Можно вызывать из любого места сайта:
   *   window.GlukTelemetry.report(err, "освобождение слота устройства")
   */
  function report(error, extra) {
    try {
      var info = describe(error);
      if (!info.message) info.message = "(no message)";
      if (!allow(info.name + "|" + info.message)) return;

      var payload = {
        platform: "web",
        appVersion: String(VERSION),
        errorName: info.name.slice(0, 200),
        errorMessage: info.message.slice(0, 1000),
        stackTrace: info.stack ? info.stack.slice(0, 8000) : null,
        context: where(extra).slice(0, 400),
      };

      /* keepalive: отчёт обязан уйти, даже если ошибка случилась при уходе со
         страницы. Заголовок Authorization не подставляется - эндпоинт
         открытый, а сервер сам достанет аккаунт из токена, если он был. */
      fetch(BASE + "/api/telemetry/error", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(payload),
        keepalive: true,
        mode: "cors",
        credentials: "omit",
      }).catch(function () {
        /* сеть недоступна - именно тот случай, когда жаловаться некому */
      });
    } catch (e) {
      /* телеметрия не имеет права падать сама */
    }
  }

  window.addEventListener("error", function (event) {
    if (!event) return;
    if (event.error) {
      report(event.error);
      return;
    }
    /* Ошибки загрузки ресурсов приходят без .error и без сообщения - их
       отправляем как отдельный вид: чаще всего это упавший CDN или
       заблокированный расширением файл. */
    if (event.message) {
      report({
        name: "ErrorEvent",
        message: event.message,
        stack: (event.filename || "") + ":" + (event.lineno || 0),
      });
    }
  });

  window.addEventListener("unhandledrejection", function (event) {
    var reason = event ? event.reason : null;
    if (reason && (reason.name || reason.message)) report(reason);
    else report({ name: "UnhandledRejection", message: String(reason) });
  });

  window.GlukTelemetry = { report: report };
})();
