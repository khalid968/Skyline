import { Injectable, Dependencies, NotFoundException } from '@nestjs/common';
import { GRAPH_TARGETS } from '../decorators/access.decorators';
import { GraphService } from '../../modules/authorization/graph.service';

// Enforces the product's defining rule on every route that names another
// principal: a user reaches exactly the people and groups an administrator has
// linked to them, and nothing else.
//
// EVERY failure is the same NotFoundException: an id that is malformed, one
// that does not exist, and one that exists but is outside the caller's graph.
// A 403 would confirm the target exists, leaking the very directory this design
// hides. The exception filter renders all 404s identically.
@Injectable()
@Dependencies(GraphService)
export class ContactGraphGuard {
  constructor(graph) {
    this.graph = graph;
  }

  async canActivate(context) {
    if (context.getType() !== 'http') return true;

    const targets = Reflect.getMetadata(GRAPH_TARGETS, context.getHandler());
    if (!targets || targets.length === 0) return true;

    const req = context.switchToHttp().getRequest();
    // Reaching here without an account means a @Public route asked for graph
    // scoping. There is no "me" to scope to, so nothing is reachable.
    if (!req.account) throw new NotFoundException();
    const me = req.account.userId;

    for (const target of targets) {
      const id = req.params && req.params[target.param];
      if (!(await this.allowed(me, target, id))) throw new NotFoundException();
    }
    return true;
  }

  allowed(me, target, id) {
    switch (target.kind) {
      case 'user':
        return target.mode === 'direct'
          ? this.graph.canMessageUser(me, id)
          : this.graph.canSeeUser(me, id);
      case 'group':
        return this.graph.isGroupMember(me, id);
      case 'chat':
        return this.graph.canAccessChat(me, id);
      case 'own-device':
        return this.graph.ownsDevice(me, id);
      case 'own-upload':
        return this.graph.ownsUpload(me, id);
      case 'attachment':
        return this.graph.canDownloadAttachment(me, id);
      default:
        return false; // an unknown kind can only be a bug, so deny
    }
  }
}
