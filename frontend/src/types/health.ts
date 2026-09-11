export type ServiceStatus = "UP" | "DOWN";

export interface ServiceHealth {
  name: string;
  status: ServiceStatus;
  latency_ms: number | null;
  detail: string | null;
}

export interface HealthReport {
  services: ServiceHealth[];
  checked_at: string;
}
