import { Injectable } from '@nestjs/common';

// Which sockets are connected to THIS process, by device and by user. Purely
// in-memory and per-instance: when the backend scales past one process, Redis
// pub/sub (FanoutService) carries an event to every instance and each one
// delivers to whoever happens to be connected to it. Nothing here is shared
// state, which is what keeps the backend stateless.
@Injectable()
export class ConnectionRegistry {
  constructor() {
    this.byDevice = new Map(); // deviceId -> { socket, userId, deviceId }
    this.byUser = new Map(); //   userId   -> Set<deviceId>
  }

  add(conn) {
    // One live socket per device. A reconnect replaces the stale one.
    const previous = this.byDevice.get(conn.deviceId);
    if (previous && previous.socket !== conn.socket)
      previous.socket.close(1000, 'replaced');

    this.byDevice.set(conn.deviceId, conn);
    if (!this.byUser.has(conn.userId)) this.byUser.set(conn.userId, new Set());
    this.byUser.get(conn.userId).add(conn.deviceId);
  }

  remove(socket) {
    for (const [deviceId, conn] of this.byDevice) {
      if (conn.socket !== socket) continue;
      this.byDevice.delete(deviceId);
      const devices = this.byUser.get(conn.userId);
      if (devices) {
        devices.delete(deviceId);
        if (devices.size === 0) this.byUser.delete(conn.userId);
      }
    }
  }

  connectionsOfUsers(userIds) {
    const out = [];
    for (const userId of new Set(userIds)) {
      for (const deviceId of this.byUser.get(userId) || [])
        out.push(this.byDevice.get(deviceId));
    }
    return out;
  }

  all() {
    return [...this.byDevice.values()];
  }

  disconnectDevice(deviceId, code = 1008, reason = 'revoked') {
    const conn = this.byDevice.get(deviceId);
    if (conn) conn.socket.close(code, reason);
  }

  disconnectUser(userId, code = 1008, reason = 'revoked') {
    for (const deviceId of [...(this.byUser.get(userId) || [])])
      this.disconnectDevice(deviceId, code, reason);
  }

  get size() {
    return this.byDevice.size;
  }
}
