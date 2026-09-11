import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { ServiceTable } from "../src/components/ServiceTable";
import type { ServiceHealth } from "../src/types/health";

const services: ServiceHealth[] = [
  { name: "user-service", status: "UP", latency_ms: 120, detail: null },
  { name: "order-service", status: "DOWN", latency_ms: null, detail: "Timeout" },
];

describe("ServiceTable", () => {
  it("renders a row per service with status and details", () => {
    render(<ServiceTable services={services} />);

    expect(screen.getByText("user-service")).toBeInTheDocument();
    expect(screen.getByText("UP")).toBeInTheDocument();
    expect(screen.getByText("120 ms")).toBeInTheDocument();

    expect(screen.getByText("order-service")).toBeInTheDocument();
    expect(screen.getByText("DOWN")).toBeInTheDocument();
    expect(screen.getByText("Timeout")).toBeInTheDocument();
  });
});
