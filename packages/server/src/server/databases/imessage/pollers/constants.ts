export const MESSAGE_FAST_LOOKBACK_MS = 1000 * 60 * 30;

export const MESSAGE_RECONCILE_LOOKBACK_MS = 1000 * 60 * 60 * 24 * 7;

export const MESSAGE_RECONCILE_INTERVAL_MS = 1000 * 60 * 5;

// Keep GUIDs through one final reconciliation after they age out of the query window.
export const MESSAGE_DEDUP_CACHE_RETENTION_MS = MESSAGE_RECONCILE_LOOKBACK_MS + MESSAGE_RECONCILE_INTERVAL_MS;

export const CHAT_DEDUP_CACHE_RETENTION_MS = 1000 * 60 * 60;
