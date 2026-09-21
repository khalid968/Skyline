const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Anything that reaches a uuid column must pass this first. Otherwise a
// malformed id would surface as a Postgres error (a 500, with a different shape
// from a not-found) and hand a caller a way to tell the two cases apart.
export const isUuid = (value) => typeof value === 'string' && UUID.test(value);
