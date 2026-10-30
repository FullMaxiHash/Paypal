import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  poweredByHeader: false,
  outputFileTracingRoot: process.env.DEALSPHERE_TRACE_ROOT || process.cwd(),
  async redirects() {
    const canonical = new URL(process.env.BETTER_AUTH_URL || "http://localhost:3000");
    if (canonical.hostname !== "localhost") return [];
    return [{ source: "/:path*", has: [{ type: "host" as const, value: "127\\.0\\.0\\.1" }], destination: `${canonical.origin}/:path*`, permanent: false }];
  },
  async headers() {
    return [{ source: "/(.*)", headers: [
      { key: "X-Content-Type-Options", value: "nosniff" },
      { key: "X-Frame-Options", value: "DENY" },
      { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
      { key: "Permissions-Policy", value: "camera=(), geolocation=()" },
      { key: "Content-Security-Policy", value: `default-src 'self'; script-src 'self' 'unsafe-inline'${process.env.NODE_ENV === "development" ? " 'unsafe-eval'" : ""}; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'` }
    ] }];
  }
};
export default nextConfig;
