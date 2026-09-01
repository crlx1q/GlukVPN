import path from "node:path"
import cors from "@fastify/cors"
import helmet from "@fastify/helmet"
import jwt from "@fastify/jwt"
import rateLimit from "@fastify/rate-limit"
import fastifyStatic from "@fastify/static"
import Fastify, { type FastifyInstance } from "fastify"
import { config } from "./config"
import { HttpError } from "./lib/errors"
import { adminRoutes } from "./routes/admin"
import { authRoutes } from "./routes/auth"
import { deployRoutes } from "./routes/deploy"
import { deviceRoutes } from "./routes/devices"
import { healthRoutes } from "./routes/health"
import { linkAuthRoutes } from "./routes/link"
import { nodeAgentRoutes } from "./routes/node"
import { nodeCatalogRoutes } from "./routes/nodes"
import { vpnRoutes } from "./routes/vpn"

export async function buildApp(): Promise<FastifyInstance> {
	const app = Fastify({
		logger: {
			level: config.LOG_LEVEL,
			// Secrets must never reach the log files.
			redact: {
				paths: [
					"req.headers.authorization",
					"req.headers.cookie",
					"req.headers['x-node-id']",
					"req.body.password",
					"req.body.refreshToken",
					"req.body.enrollmentToken",
					"res.body.accessToken",
					"res.body.refreshToken",
					"res.body.nodeToken",
				],
				censor: "[redacted]",
			},
		},
		// aaPanel's Nginx terminates TLS and forwards to 127.0.0.1.
		trustProxy: config.TRUST_PROXY,
		bodyLimit: 256 * 1024,
	})

	app.setErrorHandler((error: any, request, reply) => {
		if (error && typeof error.statusCode === "number" && error.code && typeof error.code === "string") {
			reply.code(error.statusCode).send({
				error: {
					code: error.code,
					message: error.message,
					...(error.details ? { details: error.details } : {}),
				},
			})
			return
		}

		const statusCode = typeof error.statusCode === "number" ? error.statusCode : 500
		if (statusCode === 429) {
			reply.code(429).send({
				error: { code: "too_many_requests", message: "Too many requests, slow down" },
			})
			return
		}
		if (statusCode >= 400 && statusCode < 500) {
			reply.code(statusCode).send({
				error: { code: "bad_request", message: error.message },
			})
			return
		}

		request.log.error({ err: error }, "unhandled_error")
		reply.code(500).send({
			error: { code: "internal_error", message: "Internal server error" },
		})
	})

	await app.register(helmet, {
		contentSecurityPolicy: {
			directives: {
				defaultSrc: ["'self'"],
				scriptSrc: ["'self'"],
				styleSrc: ["'self'"],
				imgSrc: ["'self'", "data:"],
				connectSrc: ["'self'"],
				objectSrc: ["'none'"],
				frameAncestors: ["'none'"],
				baseUri: ["'self'"],
				formAction: ["'self'"],
			},
		},
		// HTTPS is enforced by Nginx; HSTS is announced from here.
		hsts: { maxAge: 15552000, includeSubDomains: false, preload: false },
		referrerPolicy: { policy: "no-referrer" },
		crossOriginEmbedderPolicy: false,
	})

	await app.register(cors, {
		// Empty allowlist => browsers cannot call the API cross-origin at all.
		// The Flutter app is not a browser and is unaffected.
		origin: config.corsOrigins.length > 0 ? config.corsOrigins : false,
		methods: ["GET", "POST", "DELETE", "OPTIONS"],
		allowedHeaders: ["Content-Type", "Authorization", "X-Node-Id"],
		credentials: false,
		maxAge: 600,
	})

	await app.register(rateLimit, {
		max: config.RATE_LIMIT_MAX,
		timeWindow: config.RATE_LIMIT_WINDOW,
		keyGenerator: (request) => request.ip,
		continueExceeding: false,
	})

	await app.register(jwt, {
		secret: config.JWT_SECRET,
		sign: { algorithm: "HS256" },
		verify: { algorithms: ["HS256"] },
	})

	// Minimal admin panel (static files, same origin as the API).
	await app.register(fastifyStatic, {
		root: path.join(__dirname, "..", "public"),
		prefix: "/admin/",
		index: ["index.html"],
		list: false,
	})
	app.get("/admin", async (_request, reply) => reply.redirect("/admin/", 302))

	await app.register(healthRoutes)
	await app.register(authRoutes)
	// Sign-in by link (device-authorization grant). Shared by the desktop client
	// and the browser extension, so neither has to own a password field.
	await app.register(linkAuthRoutes)
	await app.register(nodeCatalogRoutes)
	await app.register(deviceRoutes)
	await app.register(vpnRoutes)
	await app.register(nodeAgentRoutes)
	// Admin routes live in their own scope: the requireAdmin hook is registered
	// inside that scope and must not leak into the other route groups.
	await app.register(adminRoutes)
	// Channel management (beta deploy / promote / rollback). Separate scope for
	// the same reason, and admin-only as well.
	await app.register(deployRoutes)

	app.setNotFoundHandler(async (request, reply) =>
		reply.code(404).send({
			error: { code: "not_found", message: `Route ${request.method} ${request.url} not found` },
		}),
	)

	return app
}
