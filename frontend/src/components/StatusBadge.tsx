import type { ServiceStatus } from "../types/health";

export function StatusBadge({ status }: { status: ServiceStatus }) {
  const isUp = status === "UP";
  return (
    <span className={`status-badge ${isUp ? "status-up" : "status-down"}`}>{status}</span>
  );
}
