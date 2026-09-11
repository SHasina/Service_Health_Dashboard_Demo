import type { ServiceHealth } from "../types/health";
import { StatusBadge } from "./StatusBadge";

function formatDetails(service: ServiceHealth): string {
  if (service.status === "UP") {
    return service.latency_ms !== null ? `${Math.round(service.latency_ms)} ms` : "";
  }
  return service.detail ?? "Unknown error";
}

export function ServiceTable({ services }: { services: ServiceHealth[] }) {
  return (
    <table className="service-table">
      <thead>
        <tr>
          <th>Service</th>
          <th>Status</th>
          <th>Details</th>
        </tr>
      </thead>
      <tbody>
        {services.map((service) => (
          <tr key={service.name}>
            <td>{service.name}</td>
            <td>
              <StatusBadge status={service.status} />
            </td>
            <td>{formatDetails(service)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
