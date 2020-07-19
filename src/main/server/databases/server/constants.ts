export const DEFAULT_SOCKET_PORT = 1234;
export const DEFAULT_DB_ITEMS: { [key: string]: Function } = {
    tutorial_is_done: () => 0,
    socket_port: () => DEFAULT_SOCKET_PORT,
    server_address: () => "",
    password: () => "blubbubblesisawesome",
    auto_caffeinate: () => 0,
    auto_start: () => 0
};
