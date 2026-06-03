
export enum AutoStartMethods {
    None = "none",
    Unset = "unset",
    LoginItem = "login-item",
    LaunchAgent = "launch-agent"
}

export enum ProxyServices {
    Cloudflare = "cloudflare",
    Ngrok = "ngrok",
    Zrok = "zrok",
    DynamicDNS = "dynamic-dns",
    LanURL = "lan-url"
}

export const DEFAULT_SOCKET_PORT = 1234;
export const DEFAULT_DB_ITEMS: { [key: string]: () => any } = {
    tutorial_is_done: () => 0,
    socket_port: () => DEFAULT_SOCKET_PORT,
    server_address: () => "",
    ngrok_key: () => "",
    ngrok_protocol: () => "http",
    ngrok_region: () => "us",
    ngrok_custom_domain: () => "",
    use_custom_certificate: () => 0,
    password: () => "",
    auto_caffeinate: () => 0,
    auto_start: () => 0,
    auto_start_method: () => AutoStartMethods.None,
    proxy_service: () => ProxyServices.Cloudflare,
    encrypt_coms: () => 0,
    hide_dock_icon: () => 0,
    last_fcm_restart: () => 0,
    start_via_terminal: () => 0,
    check_for_updates: () => 1,
    auto_install_updates: () => 0,
    enable_private_api: () => 0,
    enable_ft_private_api: () => 0,
    use_oled_dark_mode: () => 0,
    db_poll_interval: () => 1000,
    dock_badge: () => 1,
    start_minimized: () => 0,
    headless: () => 0,
    disable_gpu: () => 0,
    private_api_mode: (): "process-dylib" => "process-dylib",
    // String because we don't handle actual integers well.
    // That needs to change... at another time.
    // 0.0 to prevent parsing as a boolean
    start_delay: () => "0.0",
    facetime_calling: () => 0,
    zrok_token: () => "",
    zrok_reserve_tunnel: () => 0,
    zrok_reserved_name: () => "",
    zrok_reserved_token: () => "",
    landing_page_path: () => "",
    open_findmy_on_startup: () => 1,
    auto_lock_mac: () => 0,
    // Google Contacts background sync.
    // Selects the Google flow: 0 = one-time import using the built-in client
    // (implicit flow, no setup); 1 = use the user's own OAuth client for
    // offline/background sync (approach "B").
    google_contacts_use_own_client: () => 0,
    // Opt-in: disabled by default. When enabled, the server keeps the local
    // contact database in sync with the user's Google Contacts on an interval.
    google_contacts_sync_enabled: () => 0,
    // Minutes between background syncs (default: 6 hours).
    google_contacts_sync_interval: () => 360,
    // The OAuth refresh token used for offline/background access. Empty until
    // the user authorizes with offline access (authorization-code + PKCE flow).
    google_contacts_refresh_token: () => "",
    // The People API sync token, used to fetch only changes since the last sync.
    google_contacts_sync_token: () => "",
    // Timestamp (ms) of the last successful Google Contacts sync.
    google_contacts_last_sync: () => 0,
    // Optional user-provided OAuth client (approach B). When both are set, they
    // override the built-in shared client. Leave empty to use the built-in one.
    google_oauth_client_id: () => "",
    google_oauth_client_secret: () => "",
};
