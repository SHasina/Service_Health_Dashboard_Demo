export function RefreshButton({
  onClick,
  disabled,
}: {
  onClick: () => void;
  disabled: boolean;
}) {
  return (
    <button className="refresh-button" onClick={onClick} disabled={disabled}>
      {disabled ? "Refreshing..." : "Refresh"}
    </button>
  );
}
