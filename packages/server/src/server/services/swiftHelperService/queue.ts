const TIMEOUT = 10*1000;

/**
 * A helper class to handle the responses from the swift helper socket.
 */
 export class Queue {
  private queue: { [key: string]: (buf: Buffer) => void } = {};

  /**
   * Adds a callback to the queue to be called when the response is received.
   * @param {string} uuid The uuid of the SocketMessage
   * @param {(buf: Buffer) => void} cb The promise to resolve when the message is received.
   */
  enqueue(uuid: string, cb: (buf: Buffer) => void) {
      if (!(uuid in this.queue)) {
          this.queue[uuid] = cb;
          // if the socket requests takes longer than the timeout time, we should cancel it
          // by resolving the promise with null and removing it from the queue.
          setTimeout(() => {
              if (this.queue[uuid] != null) this.queue[uuid](null);
              delete this.queue[uuid];
          }, TIMEOUT);
      }
  }

  /**
   * Resolves the promise of the SocketMessage with the given uuid, and removes it from the queue.
   * @param {string} uuid The uuid of the SocketMessage
   * @param {Buffer} buf The data to resolve the promise with.
   */
  call(uuid: string, buf: Buffer) {
      if (this.queue[uuid] != null) this.queue[uuid](buf);
      delete this.queue[uuid];
  }
}