import { afterEach, describe, expect, it, vi } from "vitest";
import { BackendUnavailableError, fetchHealth } from "../src/api/healthClient";

afterEach(() => {
  vi.restoreAllMocks();
});

describe("fetchHealth", () => {
  it("returns the parsed health report on success", async () => {
    const report = {
      services: [{ name: "user-service", status: "UP", latency_ms: 100, detail: null }],
      checked_at: "2026-01-01T00:00:00Z",
    };
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({ ok: true, json: () => Promise.resolve(report) }),
    );

    await expect(fetchHealth()).resolves.toEqual(report);
  });

  it("throws BackendUnavailableError on a network failure", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockRejectedValue(new TypeError("Failed to fetch")),
    );

    await expect(fetchHealth()).rejects.toBeInstanceOf(BackendUnavailableError);
  });

  it("throws BackendUnavailableError on a non-2xx response", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: false, status: 502 }));

    await expect(fetchHealth()).rejects.toBeInstanceOf(BackendUnavailableError);
  });
});
