/** Application-level HTTP error. Messages are safe to return to clients. */
export class HttpError extends Error {
	readonly statusCode: number
	readonly code: string
	readonly details?: unknown

	constructor(
		statusCode: number,
		code: string,
		message: string,
		details?: unknown,
	) {
		super(message)
		this.name = "HttpError"
		this.statusCode = statusCode
		this.code = code
		this.details = details
	}
}

export const badRequest = (message: string, details?: unknown): HttpError =>
	new HttpError(400, "bad_request", message, details)

export const unauthorized = (message = "Unauthorized"): HttpError =>
	new HttpError(401, "unauthorized", message)

export const forbidden = (message = "Forbidden"): HttpError =>
	new HttpError(403, "forbidden", message)

export const notFound = (message = "Not found"): HttpError =>
	new HttpError(404, "not_found", message)

export const conflict = (message: string): HttpError =>
	new HttpError(409, "conflict", message)

export const tooManyRequests = (message: string, retryAfterSec?: number): HttpError =>
	new HttpError(429, "too_many_requests", message, { retryAfterSec })

export const serviceUnavailable = (message: string): HttpError =>
	new HttpError(503, "service_unavailable", message)
