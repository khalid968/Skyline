// Fails the build if any route can reach another person without going through
// the contact graph, or takes a body without validation. See route-inventory.js
// for the rules. Half of this file tests the checker itself: a checker that
// cannot fail proves nothing.
import { Controller, Get, Post, Bind, Body } from '@nestjs/common';
import { ModulesContainer } from '@nestjs/core';
import { IsString } from 'class-validator';
import { createTestDatabase } from '../db/harness';
import { createTestApp } from './app-harness';
import { findProblems, routesOf } from './route-inventory';
import {
  Public,
  RequirePermission,
  ContactTarget,
  GraphExempt,
} from '../../src/common/decorators/access.decorators';
import { Validated } from '../../src/common/decorators/validated.decorator';

class Dto {
  @IsString()
  name;
}

describe('route inventory', () => {
  describe('the real application', () => {
    let db;
    let t;
    let controllers;

    beforeAll(async () => {
      db = await createTestDatabase('inventory');
      t = await createTestApp({ db });
      const container = t.app.get(ModulesContainer);
      controllers = [...container.values()].flatMap((m) =>
        [...m.controllers.values()].map((w) => w.metatype),
      );
    }, 90000);

    afterAll(async () => {
      await t.close();
      await db.drop();
    });

    it('finds the routes it is meant to check, so a pass is not vacuous', () => {
      const paths = controllers
        .flatMap(routesOf)
        .map((r) => `${r.method} ${r.path}`);
      expect(paths).toEqual(
        expect.arrayContaining(['GET /health', 'GET /health/ready']),
      );
    });

    it('has no route that reaches another principal without the contact graph, and no unvalidated body', () => {
      expect(findProblems(controllers)).toEqual([]);
    });
  });

  describe('the checker itself catches mistakes', () => {
    const check = (Ctl) => findProblems([Ctl]);

    it('accepts a properly scoped route', () => {
      @Controller('ok')
      class Good {
        @Get(':userId')
        @ContactTarget('userId')
        one() {}
      }
      expect(check(Good)).toEqual([]);
    });

    it('flags a route whose id parameter is not graph-scoped', () => {
      @Controller('users')
      class Leaky {
        @Get(':userId')
        one() {}
      }
      expect(check(Leaky).join('\n')).toMatch(
        /:userId is not scoped to the contact graph/,
      );
    });

    it('flags EVERY unscoped parameter, not just the first', () => {
      @Controller('chats')
      class Two {
        @Get(':chatId/messages/:messageId')
        one() {}
      }
      const out = check(Two).join('\n');
      expect(out).toMatch(/:chatId/);
      expect(out).toMatch(/:messageId/);
    });

    it('flags a lookup by username, which would be directory discovery', () => {
      @Controller('users')
      class Discovery {
        @Get('by-username/:username')
        one() {}
      }
      expect(check(Discovery).join('\n')).toMatch(/:username is not scoped/);
    });

    it('flags a public route that takes a path parameter', () => {
      @Controller('open')
      class PublicWithParam {
        @Public()
        @Get(':thing')
        one() {}
      }
      expect(check(PublicWithParam).join('\n')).toMatch(
        /@Public route must not take path parameters/,
      );
    });

    it('flags a graph target that names a parameter not in the path', () => {
      @Controller('typo')
      class Typo {
        @Get(':userId')
        @ContactTarget('usreId')
        one() {}
      }
      expect(check(Typo).join('\n')).toMatch(
        /names :usreId, which is not in the path/,
      );
    });

    it('accepts an operator route that is exempt from the graph AND gated by a permission', () => {
      @Controller('admin')
      class Operator {
        @Get(':userId')
        @GraphExempt(
          'operators manage every account and are gated by permission',
        )
        @RequirePermission('users.read')
        one() {}
      }
      expect(check(Operator)).toEqual([]);
    });

    it('flags an exemption that is not backed by a permission', () => {
      @Controller('admin')
      class Naked {
        @Get(':userId')
        @GraphExempt('trust me, this one is fine, honestly')
        one() {}
      }
      expect(check(Naked).join('\n')).toMatch(
        /@GraphExempt requires @RequirePermission/,
      );
    });

    it('flags a body-taking route with no @Validated DTO', () => {
      @Controller('things')
      class Unvalidated {
        @Post()
        @Bind(Body())
        create() {}
      }
      expect(check(Unvalidated).join('\n')).toMatch(/no @Validated DTO/);
    });

    it('accepts a body-taking route that declares its DTO', () => {
      @Controller('things')
      class Validates {
        @Post()
        @Bind(Body())
        @Validated(Dto)
        create() {}
      }
      expect(check(Validates)).toEqual([]);
    });
  });

  it('refuses a GraphExempt with a throwaway reason', () => {
    expect(() => GraphExempt('n/a')).toThrow(/real reason/);
  });
});
