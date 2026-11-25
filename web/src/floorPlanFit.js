// Fitting a floor plan to its tables (owner feedback, 25 Nov 2026: the Tables page plan was far too large).
// The saved positions are percentages of a 16:9 room. Here the room is laid out at the box's width, cropped to the
// tables' bounding box (with room for chairs) and a little padding, then scaled to fit the width and a height cap.
// Positions and the relative layout never change: only the scale and the crop. The scale stays between minScale
// (the 14px labels stay at least 12px, the smallest table about 50px, over the 44px tap target) and maxScale (a few tables don't
// look tiny); a plan still too big at minScale scrolls inside its box.
export const FIT = { pad: 28, chair: 22, minScale: 0.86, maxScale: 1.35, minHeight: 240 };

// Only a small plan (up to 4 tables) is drawn larger than life; a bigger one at most at its own size, so it stays compact.
export const fitOptions = (count) => (count <= 4 ? FIT : { ...FIT, maxScale: 1 });

// boxes: [{ x, y, w, h }] (x and y in percent of the room, w and h in pixels); width: the box's width in pixels
export function fitPlan(boxes, width, maxHeight, opt = FIT) {
  if (!boxes.length || !(width > 0)) return null;
  const roomH = (width * 9) / 16;
  let left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
  for (const b of boxes) {
    const cx = (b.x / 100) * width, cy = (b.y / 100) * roomH;
    left = Math.min(left, cx - b.w / 2 - opt.chair); right = Math.max(right, cx + b.w / 2 + opt.chair);
    top = Math.min(top, cy - b.h / 2 - opt.chair); bottom = Math.max(bottom, cy + b.h / 2 + opt.chair);
  }
  const w = right - left, h = bottom - top;
  const fitScale = Math.min(opt.maxScale, (width - 2 * opt.pad) / w, (Math.max(maxHeight, opt.minHeight) - 2 * opt.pad) / h);
  const scale = Math.max(opt.minScale, fitScale);
  const height = Math.max(opt.minHeight, Math.round(Math.min(h * scale + 2 * opt.pad, Math.max(maxHeight, opt.minHeight))));
  return {
    scale, left, top, width: w, height: h, roomH, boxHeight: height,
    offsetX: Math.max(opt.pad, (width - w * scale) / 2),
    offsetY: Math.max(opt.pad, (height - h * scale) / 2),
    scrolls: w * scale + 2 * opt.pad > width + 0.5 || h * scale + 2 * opt.pad > height + 0.5,
  };
}
