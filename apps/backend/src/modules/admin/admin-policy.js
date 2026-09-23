import { ForbiddenException, NotFoundException } from '@nestjs/common';
import { isUuid } from '../../common/uuid';

// Who may act on whom. Every mutating admin operation goes through
// assertCanManage() before it touches anything.
//
//   - The OWNER (is_owner) may manage anyone. Nobody, the owner included, can
//     demote, suspend or delete the owner: the database refuses too (migration
//     010), so this check is a second line, not the only one.
//   - An ADMIN may manage moderators and members, never another admin. Creating,
//     promoting to, or removing an admin is the owner's alone (decisions.md).
//   - A MODERATOR may act on members only (and their permissions are narrow).
//   - Nobody may suspend, delete or change the role of their own account; that
//     way an operator cannot lock themselves out by accident.
//
// Operator routes answer a refusal with 403: that an operator route exists is
// not a secret (authorization.md). An unknown or deleted target is a 404.

export async function loadTarget(db, userId, { allowDeleted = false } = {}) {
  if (!isUuid(userId)) throw new NotFoundException();
  const { rows } = await db.query(
    `SELECT id, username::text AS username, display_name, role_key, status, is_owner
       FROM users WHERE id = $1`,
    [userId],
  );
  const t = rows[0];
  if (!t || (!allowDeleted && t.status === 'deleted'))
    throw new NotFoundException();
  return t;
}

export function assertCanManage(actor, target, { self = false } = {}) {
  if (target.id === actor.userId) {
    if (!self) throw new ForbiddenException();
    return;
  }
  if (target.is_owner && !actor.isOwner) throw new ForbiddenException();
  if (target.role_key === 'admin' && !actor.isOwner)
    throw new ForbiddenException();
  if (actor.role === 'moderator' && target.role_key !== 'member')
    throw new ForbiddenException();
}

// Giving someone the admin role, or taking it away, is the owner's alone.
export function assertCanAssignRole(actor, target, newRole) {
  assertCanManage(actor, target);
  if ((newRole === 'admin' || target.role_key === 'admin') && !actor.isOwner) {
    throw new ForbiddenException();
  }
}
