import type { HealthReport } from "../types/health";

export class BackendUnavailableError extends Error {}

export async function fetchHealth(): Promise<HealthReport> {
  let response: Response;
  try {
    response = await fetch("/api/health");
  } catch {
    throw new BackendUnavailableError("Could not reach the backend service");
  }

  if (!response.ok) {
    throw new BackendUnavailableError(`Backend responded with status ${response.status}`);
  }

  try {
    return (await response.json()) as HealthReport;
  } catch {
    throw new BackendUnavailableError("Backend returned an unexpected response");
  }
}
