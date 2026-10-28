import { Icon } from "../BusinessUI";
import { sidebarMode, updateAppearance, useAppearance } from "../appearance";

// Bottom of the sidebar (admin and CRM): fold it into a slim icon dock, or open it back up to the full list.
// The choice is saved with the person's appearance settings, so it is the same on every page and device.
export function DockToggle() {
  const look = useAppearance();
  const compact = sidebarMode(look) === "compact";
  return (
    <button type="button" className="zella-dock-toggle" aria-pressed={!compact}
      title={compact ? "Expand the sidebar" : "Shrink the sidebar to icons"}
      aria-label={compact ? "Expand the sidebar" : "Shrink the sidebar to icons"}
      onClick={() => updateAppearance({ sidebar: compact ? "full" : "compact" })}>
      <Icon name={compact ? "keyboard_double_arrow_right" : "keyboard_double_arrow_left"} size="sm" />
      <span className="zella-dock-label">Shrink sidebar</span>
    </button>
  );
}
