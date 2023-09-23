import { Server } from "@server";

export const DEFAULT_SOCKET_PORT = 1234;
export const DEFAULT_DB_ITEMS: { [key: string]: () => any } = {
    tutorial_is_done: () => 0,
    socket_port: () => DEFAULT_SOCKET_PORT,
    server_address: () => "",
    ngrok_key: () => "",
    ngrok_protocol: () => "http",
    ngrok_region: () => "us",
    use_custom_certificate: () => 0,
    password: () => "",
    auto_caffeinate: () => 0,
    auto_start: () => 0,
    proxy_service: () => "Cloudflare",
    encrypt_coms: () => 0,
    hide_dock_icon: () => 0,
    last_fcm_restart: () => 0,
    start_via_terminal: () => 0,
    check_for_updates: () => 1,
    auto_install_updates: () => 0,
    enable_private_api: () => 0,
    use_oled_dark_mode: () => 0,
    db_poll_interval: () => 1000,
    dock_badge: () => 1,
    start_minimized: () => 0,
    headless: () => 0,
    private_api_mode: (): 'process-dylib' => 'process-dylib'
};
