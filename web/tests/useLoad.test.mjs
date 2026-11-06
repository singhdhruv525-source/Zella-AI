import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

// Exercise the actual hook with a small lifecycle harness, without a DOM or database.
const source = readFileSync(new URL("../src/BusinessShared.jsx", import.meta.url), "utf8");
const hook = source.slice(source.indexOf("export function useLoad("), source.indexOf("export function orThrow("))
  .replace("export function", "function");
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
};
const flush = async () => { await Promise.resolve(); await Promise.resolve(); };

function mount(loader, deps) {
  let state, callback, callbackDeps, effectDeps, cleanup, pendingEffect;
  const ref = { current: 0 };
  const changed = (a, b) => !a || a.length !== b.length || a.some((v, i) => !Object.is(v, b[i]));
  const context = vm.createContext({
    useState(initial) {
      state ??= initial;
      return [state, (next) => { state = typeof next === "function" ? next(state) : next; }];
    },
    useRef: () => ref,
    useCallback(fn, nextDeps) {
      if (changed(callbackDeps, nextDeps)) { callback = fn; callbackDeps = nextDeps; }
      return callback;
    },
    useEffect(fn, nextDeps) {
      if (changed(effectDeps, nextDeps)) { pendingEffect = fn; effectDeps = nextDeps; }
    },
    friendly: (err) => err.message,
  });
  const invokeHook = vm.runInContext(`${hook}\nuseLoad`, context);
  const render = (nextLoader = loader, nextDeps = deps) => {
    const result = invokeHook(nextLoader, nextDeps);
    if (pendingEffect) {
      cleanup?.();
      const effect = pendingEffect;
      pendingEffect = null;
      cleanup = effect();
    }
    return result;
  };
  render();
  return { render, state: () => state, unmount: () => cleanup?.() };
}

for (const outcome of ["resolve", "reject"]) {
  test(`superseded ${outcome} cannot replace current data or error`, async () => {
    const old = deferred(), latest = deferred();
    const h = mount(() => old.promise, ["old IDs"]);
    h.render(() => latest.promise, ["current IDs"]);
    latest.resolve({ current: "current page data" });
    await flush();
    const current = h.state();
    old[outcome](outcome === "resolve" ? { old: "old page data" } : new Error("old failure"));
    await flush();
    assert.equal(h.state(), current);
    assert.equal(current.data.current, "current page data");
    assert.equal(current.error, "");
    assert.equal(current.loading, false);
  });
}

test("overlapping reloads ignore stale results while the newest request is pending", async () => {
  const first = deferred(), second = deferred();
  let calls = 0;
  const h = mount(() => (++calls === 1 ? first.promise : second.promise), []);
  const reload = h.render().reload;
  const running = reload();
  first.resolve("stale");
  await flush();
  assert.equal(h.state().loading, true);
  assert.equal(h.state().data, null);
  second.resolve("latest");
  await running;
  assert.equal(h.state().data, "latest");
});

test("latest errors preserve data; retry clears the error and loads new data", async () => {
  const h = mount(async () => "saved titles", []);
  await flush();
  h.render(async () => { throw new Error("lookup failed"); }, ["new IDs"]);
  await flush();
  assert.equal(h.state().data, "saved titles");
  assert.equal(h.state().error, "lookup failed");
  assert.equal(h.state().loading, false);
  const retry = deferred();
  h.render(() => retry.promise, ["retry"]);
  assert.equal(h.state().error, "");
  assert.equal(h.state().loading, true);
  assert.equal(h.state().data, "saved titles");
  retry.resolve("new titles");
  await flush();
  assert.equal(h.state().data, "new titles");
});

for (const outcome of ["resolve", "reject"]) {
  test(`cleanup discards a pending ${outcome}`, async () => {
    const pending = deferred();
    const h = mount(() => pending.promise, []);
    const before = h.state();
    h.unmount();
    pending[outcome](outcome === "resolve" ? "late" : new Error("late failure"));
    await flush();
    assert.equal(h.state(), before);
  });
}
