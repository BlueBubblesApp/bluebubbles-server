import { generateUuid } from "@server/helpers/utils";

export const DEFAULT_POLL_FREQUENCY_MS = 1000;
export const DEFAULT_SOCKET_PORT = 1234;
export const DEFAULT_DB_ITEMS: { [key: string]: Function } = {
    tutorial_is_done: () => 0,
    socket_port: () => DEFAULT_SOCKET_PORT,
    server_address: () => "",
    guid: () => generateUuid(),
    auto_caffeinate: () => 0,
    auto_start: () => 0
};
