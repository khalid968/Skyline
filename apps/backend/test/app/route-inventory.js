// Enumerates every HTTP route in a set of controllers and reports any that are
// not protected the way Skyline requires. This turns "every endpoint that takes
// an id goes through the contact graph" from a code-review convention into a
// test that fails the build.
//
// The rules, per route:
//   PUBLIC route      takes no path parameters, no graph targets, no permissions.
//   any other route   every path parameter must be either
//                       - covered by a graph decorator (@ContactTarget /
//                         @GroupTarget / @ChatTarget) naming that parameter, or
//                       - the route carries @GraphExempt(reason) AND
//                         @RequirePermission(...), for operator routes that act
//                         on anyone and are gated by permission instead.
//   graph decorator   must name a parameter that is really in the path.
//   @GraphExempt      pointless without a parameter, and unsafe without a permission.
//   body-taking route must declare its DTO with @Validated, or the global
//                     validation pipe silently checks nothing (plain JS has no
//                     compiler-emitted type metadata).
import 'reflect-metadata';
import {
  PATH_METADATA,
  METHOD_METADATA,
  ROUTE_ARGS_METADATA,
} from '@nestjs/common/constants';
import {
  IS_PUBLIC,
  REQUIRED_PERMISSIONS,
  GRAPH_TARGETS,
  GRAPH_EXEMPT,
} from '../../src/common/decorators/access.decorators';

const METHODS = [
  'GET',
  'POST',
  'PUT',
  'DELETE',
  'PATCH',
  'ALL',
  'OPTIONS',
  'HEAD',
];
const BODY_PARAMTYPE = 3; // RouteParamtypes.BODY

export function routesOf(controller) {
  const proto = controller.prototype;
  const base = Reflect.getMetadata(PATH_METADATA, controller) ?? '';

  return Object.getOwnPropertyNames(proto)
    .filter(
      (n) =>
        n !== 'constructor' &&
        typeof proto[n] === 'function' &&
        Reflect.hasMetadata(METHOD_METADATA, proto[n]),
    )
    .map((name) => {
      const handler = proto[name];
      const sub = Reflect.getMetadata(PATH_METADATA, handler) ?? '';
      return {
        controller,
        name,
        handler,
        method: METHODS[Reflect.getMetadata(METHOD_METADATA, handler)] || 'ANY',
        // Collapse doubled slashes and drop a trailing one ("/health/" -> "/health").
        path: `/${[base, sub].join('/')}`
          .replace(/\/+/g, '/')
          .replace(/(.)\/$/, '$1'),
      };
    });
}

const paramsIn = (path) =>
  [...path.matchAll(/:([A-Za-z0-9_]+)/g)].map((m) => m[1]);

export function findProblems(controllers) {
  const problems = [];

  for (const controller of controllers) {
    for (const r of routesOf(controller)) {
      const label = `${r.method} ${r.path} (${controller.name}.${r.name})`;
      const params = paramsIn(r.path);

      const isPublic = !!(
        Reflect.getMetadata(IS_PUBLIC, r.handler) ||
        Reflect.getMetadata(IS_PUBLIC, controller)
      );
      const perms =
        Reflect.getMetadata(REQUIRED_PERMISSIONS, r.handler) ||
        Reflect.getMetadata(REQUIRED_PERMISSIONS, controller) ||
        [];
      const targets = Reflect.getMetadata(GRAPH_TARGETS, r.handler) || [];
      const exempt = Reflect.getMetadata(GRAPH_EXEMPT, r.handler);

      if (isPublic) {
        if (params.length)
          problems.push(
            `${label}: a @Public route must not take path parameters (${params.join(', ')})`,
          );
        if (targets.length)
          problems.push(`${label}: a @Public route cannot be graph-scoped`);
        if (perms.length)
          problems.push(`${label}: a @Public route cannot require permissions`);
      } else {
        for (const p of params) {
          const covered =
            targets.some((t) => t.param === p) || (exempt && perms.length > 0);
          if (!covered) {
            problems.push(
              `${label}: path parameter :${p} is not scoped to the contact graph`,
            );
          }
        }
      }

      for (const t of targets) {
        if (!params.includes(t.param)) {
          problems.push(
            `${label}: graph target names :${t.param}, which is not in the path`,
          );
        }
      }
      if (exempt) {
        if (params.length === 0)
          problems.push(
            `${label}: @GraphExempt on a route with no path parameters is pointless`,
          );
        if (perms.length === 0)
          problems.push(`${label}: @GraphExempt requires @RequirePermission`);
      }

      const args =
        Reflect.getMetadata(ROUTE_ARGS_METADATA, controller, r.name) || {};
      const bodyIndexes = Object.keys(args)
        .filter((k) => Number(k.split(':')[0]) === BODY_PARAMTYPE)
        .map((k) => args[k].index);
      if (bodyIndexes.length) {
        const types =
          Reflect.getMetadata(
            'design:paramtypes',
            controller.prototype,
            r.name,
          ) || [];
        for (const i of bodyIndexes) {
          if (typeof types[i] !== 'function') {
            problems.push(
              `${label}: takes a body but has no @Validated DTO, so it is not validated`,
            );
          }
        }
      }
    }
  }

  return problems;
}
