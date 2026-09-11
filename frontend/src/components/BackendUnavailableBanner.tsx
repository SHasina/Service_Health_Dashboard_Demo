export function BackendUnavailableBanner({ message }: { message: string }) {
  return (
    <div className="backend-unavailable-banner" role="alert">
      <strong>Backend unavailable.</strong> {message}
    </div>
  );
}
