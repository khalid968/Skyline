import { Injectable, Dependencies, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { RedisService } from '../../redis/redis.module';
import { GraphService } from '../authorization/graph.service';
import { ConnectionRegistry } from './connection-registry';
import { isUuid } from '../../common/uuid';

const TYPE = /^[a-z][a-z0-9_.]{0,63}$/;
const MAX_RECIPIENTS = 1000;
const MAX_PAYLOAD_BYTES = 64 * 1024;
const OPEN = 1; // WebSocket.OPEN

// Delivers an event from a sender to the connected devices of its recipients.
//
//   publish()      any instance -> Redis pub/sub -> every instance
//   deliverLocal() each instance sends to whoever is connected to IT
//
// THE RULE: an event never reaches a device whose user is not in the sender's
// contact graph, and that is decided when the event is DELIVERED, not when the
// socket was opened. So revoking a link, suspending a user or revoking a device
// stops delivery on an already-open socket immediately, not on reconnect.
//
// The payload is opaque here: in Phase 8 it is ciphertext, and this service
// never looks inside it.
@Injectable()
@Dependencies(RedisService, ConfigService, ConnectionRegistry, GraphService)
export class FanoutService {
  constructor(redis, config, registry, graph) {
    this.redis = redis;
    this.registry = registry;
    this.graph = graph;
    this.channel = config.get('redis.channel');
    this.logger = new Logger('Fanout');
    this.subscriber = null;
  }

  async onModuleInit() {
    this.subscriber = this.redis.duplicate();
    this.subscriber.on('error', (err) =>
      this.logger.error(`subscriber: ${err.message}`),
    );
    this.subscriber.on('message', (_channel, raw) => {
      this.handleRaw(raw).catch((err) =>
        this.logger.error(`delivery failed: ${err.message}`),
      );
    });
    await this.subscriber.subscribe(this.channel);
  }

  async onModuleDestroy() {
    if (this.subscriber) {
      await this.subscriber.quit().catch(() => this.subscriber.disconnect());
    }
  }

  publish(event) {
    assertValid(event);
    return this.redis.publish(this.channel, JSON.stringify(event));
  }

  async handleRaw(raw) {
    let event;
    try {
      event = JSON.parse(raw);
      assertValid(event);
    } catch {
      // Anything on the channel that is not a well-formed event is ignored.
      this.logger.warn('discarded a malformed event');
      return 0;
    }
    return this.deliverLocal(event);
  }

  // Returns how many sockets received the event, which is what the tests
  // assert on.
  async deliverLocal(event) {
    const conns = this.registry.connectionsOfUsers(event.recipientUserIds);
    if (conns.length === 0) return 0;

    const allowed = await this.graph.deliverableDevices(
      event.senderUserId,
      conns.map((c) => c.deviceId),
    );

    const frame = JSON.stringify({
      type: event.type,
      from: event.senderUserId,
      payload: event.payload,
    });
    let delivered = 0;
    let refused = 0;
    for (const c of conns) {
      if (!allowed.has(c.deviceId)) {
        refused++;
        continue;
      }
      if (c.socket.readyState === OPEN) {
        c.socket.send(frame);
        delivered++;
      }
    }

    if (refused > 0) {
      // Counts only. Who tried to reach whom is exactly what stays private.
      this.logger.warn(
        `refused ${refused} delivery(ies) outside the sender's contact graph`,
      );
    }
    return delivered;
  }
}

function assertValid(event) {
  const ok =
    event &&
    typeof event.type === 'string' &&
    TYPE.test(event.type) &&
    isUuid(event.senderUserId) &&
    Array.isArray(event.recipientUserIds) &&
    event.recipientUserIds.length > 0 &&
    event.recipientUserIds.length <= MAX_RECIPIENTS &&
    event.recipientUserIds.every(isUuid) &&
    event.payload !== null &&
    typeof event.payload === 'object' &&
    JSON.stringify(event.payload).length <= MAX_PAYLOAD_BYTES;

  if (!ok) throw new Error('invalid event');
}
