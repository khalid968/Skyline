import { SetMetadata } from '@nestjs/common';

// Declarative access control. Every route is DENIED by default; these
// decorators are how a route says what it needs. They are plain metadata, so a
// test can enumerate every route and prove none was left unprotected
// (test/app/route-inventory.e2e-spec.js).

export const IS_PUBLIC = 'skyline:public';
export const REQUIRED_PERMISSIONS = 'skyline:permissions';
export const GRAPH_TARGETS = 'skyline:graph-targets';
export const GRAPH_EXEMPT = 'skyline:graph-exempt';
export const DASHBOARD_SESSION = 'skyline:dashboard-session';

// No authentication required. Use for health checks and the activation flow,
// and almost nothing else.
export const Public = () => SetMetadata(IS_PUBLIC, true);

// The caller's role must hold EVERY listed permission (see the `permissions`
// table). There is deliberately no permission for reading message content.
export const RequirePermission = (...keys) =>
  SetMetadata(REQUIRED_PERMISSIONS, keys);

// A route parameter names another principal the caller wants to reach. The
// contact graph decides whether they may. Anything outside their graph gets a
// 404 identical to "does not exist", never a 403.
//
//   mode 'visible' (default): the target is a contact or shares a group with
//                             the caller, enough to see who they are.
//   mode 'direct':            a direct link is required, enough to message.
function addTarget(target) {
  return (_cls, _key, descriptor) => {
    const handler = descriptor.value;
    const existing = Reflect.getMetadata(GRAPH_TARGETS, handler) || [];
    Reflect.defineMetadata(GRAPH_TARGETS, [...existing, target], handler);
    return descriptor;
  };
}

export const ContactTarget = (param, { mode = 'visible' } = {}) => {
  if (mode !== 'visible' && mode !== 'direct')
    throw new Error(`unknown ContactTarget mode: ${mode}`);
  return addTarget({ kind: 'user', param, mode });
};
export const GroupTarget = (param) => addTarget({ kind: 'group', param });
export const ChatTarget = (param) => addTarget({ kind: 'chat', param });
// A device id that must belong to the caller (listing or revoking their own
// devices). Someone else's device is a 404, like anything outside the graph.
export const OwnDeviceTarget = (param) =>
  addTarget({ kind: 'own-device', param });

// Which kind of session a route accepts. A route that requires a permission is
// an OPERATOR route and accepts only a dashboard session; every other
// authenticated route is a MEMBER route and accepts only a device session.
// That enforces the locked decision that admin tooling is separate from the
// app: even an admin's own phone cannot call operator APIs.
//
// This marks the few operator routes that need a dashboard session but no
// particular permission (sign out, 2FA setup, change password).
export const DashboardSession = () => SetMetadata(DASHBOARD_SESSION, true);

// For a route that takes an id but is legitimately not scoped to the caller's
// graph, chiefly admin routes that act on any user and are gated by a
// permission instead. A written reason is REQUIRED, and the inventory test
// insists such a route also carries @RequirePermission.
export const GraphExempt = (reason) => {
  if (typeof reason !== 'string' || reason.trim().length < 10) {
    throw new Error('GraphExempt needs a real reason (at least 10 characters)');
  }
  return SetMetadata(GRAPH_EXEMPT, reason);
};
