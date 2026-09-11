import { useCallback, useEffect, useState } from "react";
import { BackendUnavailableError, fetchHealth } from "./api/healthClient";
import { BackendUnavailableBanner } from "./components/BackendUnavailableBanner";
import { RefreshButton } from "./components/RefreshButton";
import { ServiceTable } from "./components/ServiceTable";
import type { ServiceHealth } from "./types/health";

type LoadState =
  | { status: "loading" }
  | { status: "loaded"; services: ServiceHealth[]; checkedAt: string }
  | { status: "error"; message: string };

export function App() {
  const [state, setState] = useState<LoadState>({ status: "loading" });
  const [refreshing, setRefreshing] = useState(false);

  const load = useCallback(async () => {
    setRefreshing(true);
    try {
      const report = await fetchHealth();
      setState({ status: "loaded", services: report.services, checkedAt: report.checked_at });
    } catch (error) {
      const message =
        error instanceof BackendUnavailableError ? error.message : "Unexpected error";
      setState({ status: "error", message });
    } finally {
      setRefreshing(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  return (
    <main className="app">
      <header className="app-header">
        <h1>Service Health Dashboard</h1>
        <RefreshButton onClick={load} disabled={refreshing} />
      </header>

      {state.status === "error" && <BackendUnavailableBanner message={state.message} />}
      {state.status === "loading" && <p>Loading service status...</p>}
      {state.status === "loaded" && (
        <>
          <ServiceTable services={state.services} />
          <p className="checked-at">Last checked: {new Date(state.checkedAt).toLocaleString()}</p>
        </>
      )}
    </main>
  );
}
