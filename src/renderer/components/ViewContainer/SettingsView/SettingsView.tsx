/* eslint-disable react/no-array-index-key */
/* eslint-disable class-methods-use-this */
/* eslint-disable jsx-a11y/label-has-associated-control */
/* eslint-disable max-len */
/* eslint-disable react/no-unused-state */
/* eslint-disable react/prefer-stateless-function */
import * as React from "react";
import { ipcRenderer } from "electron";
import Dropzone from "react-dropzone";
import { isValidServerConfig, isValidClientConfig, invokeMain, checkFirebaseUrl } from "@renderer/helpers/utils";
import TopNav from "@renderer/components/TopNav/TopNav";
import LeftStatusIndicator from "../DashboardView/LeftStatusIndicator/LeftStatusIndicator";

import "./SettingsView.css";

interface State {
    config: any;
    serverPort: string;
    fcmClient: any;
    fcmServer: any;
    autoCaffeinate: boolean;
    isCaffeinated: boolean;
    autoStart: boolean;
    serverPassword: string;
    showPassword: boolean;
    showKey: boolean;
    ngrokKey: string;
    ngrokProtocol: string;
    ngrokRegion: string;
    enableNgrok: boolean;
    proxyService: string;
    showModal: boolean;
    serverUrl: string;
    encryptComs: boolean;
    hideDockIcon: boolean;
    startViaTerminal: boolean;
    checkForUpdates: boolean;
    autoInstallUpdates: boolean;
    enablePrivateApi: boolean;
}

class SettingsView extends React.Component<unknown, State> {
    constructor(props: unknown) {
        super(props);

        this.state = {
            config: null,
            serverPort: "",
            fcmClient: null,
            fcmServer: null,
            autoCaffeinate: false,
            isCaffeinated: false,
            autoStart: false,
            serverPassword: "",
            showPassword: false,
            showKey: false,
            proxyService: "Dynamic DNS",
            ngrokKey: "",
            ngrokProtocol: "http",
            ngrokRegion: "us",
            enableNgrok: false,
            showModal: false,
            serverUrl: "",
            encryptComs: false,
            hideDockIcon: false,
            startViaTerminal: false,
            checkForUpdates: true,
            autoInstallUpdates: false,
            enablePrivateApi: false
        };

        this.handleInputChange = this.handleInputChange.bind(this);
    }

    async componentDidMount() {
        const currentTheme = await ipcRenderer.invoke("get-current-theme");
        await this.setTheme(currentTheme.currentTheme);

        const config = await ipcRenderer.invoke("get-config");
        if (config)
            this.setState({
                config,
                serverPort: String(config.socket_port),
                fcmClient: null,
                fcmServer: null,
                autoCaffeinate: config.auto_caffeinate,
                isCaffeinated: false,
                autoStart: config.auto_start,
                serverPassword: config.password,
                showPassword: false,
                showKey: false,
                proxyService: config.proxy_service,
                ngrokKey: config.ngrok_key,
                ngrokProtocol: config.ngrok_protocol,
                ngrokRegion: config.ngrok_region,
                enableNgrok: config.enable_ngrok,
                encryptComs: config.encrypt_coms,
                hideDockIcon: config.hide_dock_icon,
                startViaTerminal: config.start_via_terminal,
                checkForUpdates: config.check_for_updates,
                autoInstallUpdates: config.auto_install_updates,
                enablePrivateApi: config.enable_private_api
            });

        this.getCaffeinateStatus();

        const client = await ipcRenderer.invoke("get-fcm-client");
        if (client) this.setState({ fcmClient: JSON.stringify(client) });
        const server = await ipcRenderer.invoke("get-fcm-server");
        if (server) this.setState({ fcmServer: JSON.stringify(server) });

        ipcRenderer.on("config-update", (event, arg) => {
            this.setState({ config: arg });
        });
    }

    componentWillUnmount() {
        ipcRenderer.removeAllListeners("config-update");
    }

    async setTheme(currentTheme: string) {
        const themedItems = document.querySelectorAll("[data-theme]");

        if (currentTheme === "dark") {
            themedItems.forEach(item => {
                item.setAttribute("data-theme", "dark");
            });
        } else {
            themedItems.forEach(item => {
                item.setAttribute("data-theme", "light");
            });
        }
    }

    getCaffeinateStatus = async () => {
        const caffeinateStatus = await ipcRenderer.invoke("get-caffeinate-status");
        this.setState({
            isCaffeinated: caffeinateStatus.isCaffeinated,
            autoCaffeinate: caffeinateStatus.autoCaffeinate
        });
    };

    toggleShowPassword = () => {
        this.setState({ showPassword: !this.state.showPassword });
    };

    toggleShowKey = () => {
        this.setState({ showKey: !this.state.showKey });
    };

    saveCustomServerUrl = (save: boolean) => {
        if (save) {
            ipcRenderer.invoke("set-config", {
                server_address: this.state.serverUrl
            });
        }

        this.setState({ showModal: false });
    };

    handleProxyChange = async (e: any) => {
        // eslint-disable-next-line prefer-destructuring
        const value = e.target.value as string;
        this.setState({ proxyService: value });
        await ipcRenderer.invoke("toggle-proxy-service", { service: value });

        if (value === "Dynamic DNS") {
            this.setState({ showModal: true });
        }
    };

    handleProtocolChange = async (e: any) => {
        // eslint-disable-next-line prefer-destructuring
        const value = e.target.value as string;
        this.setState({ ngrokProtocol: value });
        await ipcRenderer.invoke("toggle-ngrok-protocol", { protocol: value });
    };

    handleRegionChange = async (e: any) => {
        // eslint-disable-next-line prefer-destructuring
        const value = e.target.value as string;
        this.setState({ ngrokRegion: value });
        await ipcRenderer.invoke("toggle-ngrok-region", { region: value });
    };

    setNgrokKey = async () => {
        await ipcRenderer.invoke("set-ngrok-key", { key: this.state.ngrokKey });
    };

    handleInputChange = async (e: any) => {
        // eslint-disable-next-line prefer-destructuring
        const id = e.target.id;
        if (["serverPort", "serverPassword", "ngrokKey", "serverUrl"].includes(id)) {
            this.setState({ [id]: e.target.value } as any);
        }

        if (id === "toggleNgrok") {
            const target = e.target as HTMLInputElement;
            this.setState({ enableNgrok: target.checked });
            await ipcRenderer.invoke("toggle-ngrok", target.checked!);

            if (!target.checked) {
                this.setState({ showModal: true });
            }
        }

        if (id === "togglePrivateApi") {
            const target = e.target as HTMLInputElement;
            this.setState({ enablePrivateApi: target.checked });
            await ipcRenderer.invoke("toggle-private-api", target.checked!);
        }

        if (id === "toggleCaffeinate") {
            const target = e.target as HTMLInputElement;
            this.setState({ autoCaffeinate: target.checked });
            await ipcRenderer.invoke("toggle-caffeinate", target.checked);
            await this.getCaffeinateStatus();
        }

        if (id === "toggleAutoStart") {
            const target = e.target as HTMLInputElement;
            this.setState({ autoStart: target.checked });
            await ipcRenderer.invoke("toggle-auto-start", target.checked);
        }

        if (id === "toggleEncrypt") {
            const target = e.target as HTMLInputElement;
            this.setState({ encryptComs: target.checked });
            await ipcRenderer.invoke("set-config", {
                encrypt_coms: target.checked
            });
        }

        if (id === "toggleDockIcon") {
            const target = e.target as HTMLInputElement;
            this.setState({ hideDockIcon: target.checked });
            await ipcRenderer.invoke("set-config", {
                hide_dock_icon: target.checked
            });
        }

        if (id === "toggleTerminalStart") {
            const target = e.target as HTMLInputElement;
            this.setState({ startViaTerminal: target.checked });
            await ipcRenderer.invoke("set-config", {
                start_via_terminal: target.checked
            });
        }

        if (id === "toggleCheckForUpdates") {
            const target = e.target as HTMLInputElement;
            this.setState({ checkForUpdates: target.checked });
            await ipcRenderer.invoke("set-config", {
                check_for_updates: target.checked
            });
        }

        if (id === "toggleAutoInstallUpdates") {
            const target = e.target as HTMLInputElement;
            this.setState({ autoInstallUpdates: target.checked });
            await ipcRenderer.invoke("set-config", {
                auto_install_updates: target.checked
            });
        }
    };

    saveConfig = async () => {
        await ipcRenderer.invoke("set-config", {
            socket_port: this.state.serverPort,
            password: this.state.serverPassword,
            ngrok_key: this.state.ngrokKey
        });
    };

    handleClientFile = (acceptedFiles: any) => {
        const reader = new FileReader();

        reader.onabort = () => console.log("file reading was aborted");
        reader.onerror = () => console.log("file reading has failed");
        reader.onload = () => {
            // Do whatever you want with the file contents
            const binaryStr = reader.result;
            const valid = isValidClientConfig(binaryStr as string);
            const validServer = isValidServerConfig(binaryStr as string);
            const jsonData = JSON.parse(binaryStr as string);

            if (valid) {
                const test = checkFirebaseUrl(jsonData);
                if (test) {
                    ipcRenderer.invoke("set-fcm-client", jsonData);
                    this.setState({ fcmClient: binaryStr });
                }
            } else if (validServer) {
                ipcRenderer.invoke("set-fcm-server", jsonData);
                this.setState({ fcmServer: binaryStr });

                invokeMain("show-dialog", {
                    type: "warning",
                    buttons: ["OK"],
                    title: "BlueBubbles Warning",
                    message: "We've corrected a mistake you made",
                    detail:
                        `The file you chose was for the FCM Server configuration and ` +
                        `we've saved it as such. Now, please choose the correct client configuration.`
                });
            } else {
                invokeMain("show-dialog", {
                    type: "error",
                    buttons: ["OK"],
                    title: "BlueBubbles Error",
                    message: "Invalid FCM Client configuration selected!",
                    detail: "The file you have selected is not in the correct format!"
                });
            }
        };

        reader.readAsText(acceptedFiles[0]);
    };

    handleServerFile = (acceptedFiles: any) => {
        const reader = new FileReader();

        reader.onabort = () => console.log("file reading was aborted");
        reader.onerror = () => console.log("file reading has failed");
        reader.onload = () => {
            // Do whatever you want with the file contents
            const binaryStr = reader.result;
            const valid = isValidServerConfig(binaryStr as string);
            const validClient = isValidClientConfig(binaryStr as string);
            const jsonData = JSON.parse(binaryStr as string);

            if (valid) {
                ipcRenderer.invoke("set-fcm-server", jsonData);
                this.setState({ fcmServer: binaryStr });
            } else if (validClient) {
                const test = checkFirebaseUrl(jsonData);
                if (test) {
                    ipcRenderer.invoke("set-fcm-client", jsonData);
                    this.setState({ fcmClient: binaryStr });

                    invokeMain("show-dialog", {
                        type: "warning",
                        buttons: ["OK"],
                        title: "BlueBubbles Warning",
                        message: "We've corrected a mistake you made",
                        detail:
                            `The file you chose was for the FCM Client configuration and ` +
                            `we've saved it as such. Now, please choose the correct server configuration.`
                    });
                }
            } else {
                invokeMain("show-dialog", {
                    type: "error",
                    buttons: ["OK"],
                    title: "BlueBubbles Error",
                    message: "Invalid FCM Server configuration selected!",
                    detail: "The file you have selected is not in the correct format!"
                });
            }
        };

        reader.readAsText(acceptedFiles[0]);
    };

    render() {
        return (
            <div id="SettingsView" data-theme="light">
                <TopNav header="Settings" />
                <div id="settingsLowerContainer">
                    <LeftStatusIndicator />
                    <div id="settingsMainRightContainer">
                        <h3 className="aSettingTitle">Server Address:</h3>
                        <input
                            readOnly
                            className="aInput"
                            placeholder="No server address specified..."
                            value={this.state.config ? this.state.config.server_address : ""}
                        />
                        <h3 className="aSettingTitle">Local Port:</h3>
                        <input
                            id="serverPort"
                            className="aInput"
                            value={this.state.serverPort}
                            onChange={e => this.handleInputChange(e)}
                            onBlur={() => this.saveConfig()}
                        />
                        <h3 className="aSettingTitle">Server Password:</h3>
                        <span>
                            <input
                                id="serverPassword"
                                className="aInput"
                                value={this.state.serverPassword}
                                onChange={e => this.handleInputChange(e)}
                                onBlur={() => this.saveConfig()}
                                type={this.state.showPassword ? "text" : "password"}
                            />
                            <svg
                                id="passwordView"
                                viewBox="0 0 512 512"
                                onClick={() => this.setState({ showPassword: !this.state.showPassword })}
                            >
                                <g>
                                    <path d="M234.667,170.667c-35.307,0-64,28.693-64,64s28.693,64,64,64s64-28.693,64-64S269.973,170.667,234.667,170.667z" />
                                    <path
                                        d="M234.667,74.667C128,74.667,36.907,141.013,0,234.667c36.907,93.653,128,160,234.667,160
                                        c106.773,0,197.76-66.347,234.667-160C432.427,141.013,341.44,74.667,234.667,74.667z M234.667,341.333
                                        c-58.88,0-106.667-47.787-106.667-106.667S175.787,128,234.667,128s106.667,47.787,106.667,106.667
                                        S293.547,341.333,234.667,341.333z"
                                    />
                                </g>
                            </svg>
                        </span>

                        <div className="aCheckboxDiv firstCheckBox">
                            <div>
                                <h3 className="aSettingTitle">Encrypt Communications (Do not use with Desktop App)</h3>
                                <p className="settingsHelp">
                                    Messages sent back to the clients will be encrypted using AES password-based
                                    encryption. The Desktop app does not yet support this option!
                                </p>
                            </div>
                            <label className="form-switch">
                                <input
                                    id="toggleEncrypt"
                                    onChange={e => this.handleInputChange(e)}
                                    type="checkbox"
                                    checked={this.state.encryptComs}
                                />
                                <i />
                            </label>
                        </div>
                        <span>
                            <div>
                                <h3 className="aSettingTitle">Proxy Service:</h3>
                                <p className="settingsHelp">
                                    Select which proxy service you want to use with BlueBubbles. If you are having
                                    issues with Ngrok, please sign up on their website and use your account&apos;s Auth
                                    Token. Otherwise, try out LocalTunnel.
                                </p>
                            </div>

                            <select value={this.state.proxyService} onChange={e => this.handleProxyChange(e)}>
                                <option value="Ngrok">Ngrok</option>
                                <option value="Cloudflare">Cloudflare</option>
                                <option value="LocalTunnel">LocalTunnel</option>
                                <option value="Dynamic DNS">Dynamic DNS</option>
                            </select>
                        </span>
                        {this.state.proxyService === "Ngrok" ? (
                            <span>
                                <div>
                                    <h3 className="aSettingTitle">Ngrok Region:</h3>
                                    <p className="settingsHelp">
                                        Select the region that is closest to you. The closer the server, the better
                                        latency will be.
                                    </p>
                                </div>
                                <select value={this.state.ngrokRegion} onChange={e => this.handleRegionChange(e)}>
                                    <option value="us">United States (Ohio)</option>
                                    <option value="eu">Europe (Frankfurt)</option>
                                    <option value="ap">Asia/Pacific (Singapore)</option>
                                    <option value="au">Australia (Sydney)</option>
                                    <option value="sa">South America (Sao Paulo)</option>
                                    <option value="jp">Japan (Tokyo)</option>
                                    <option value="in">India (Mumbai)</option>
                                </select>
                            </span>
                        ) : null}
                        {this.state.proxyService === "Ngrok" ? (
                            <span>
                                <div>
                                    <h3 className="aSettingTitle">Ngrok Auth Token (optional):</h3>
                                    <p className="settingsHelp">
                                        Using an Auth Token will allow you to use the benefits of the upgraded Ngrok
                                        service. This is not referring to the API Keys in Ngrok. Note, if you want to
                                        use TCP, an Auth Token is required.
                                    </p>
                                </div>
                                <input
                                    id="ngrokKey"
                                    className="aInput"
                                    placeholder="No key uploaded"
                                    value={this.state.ngrokKey}
                                    onChange={e => this.handleInputChange(e)}
                                    onBlur={() => this.saveConfig()}
                                />
                                <button className="modal-button" onClick={() => this.setNgrokKey()}>
                                    Save Key
                                </button>
                            </span>
                        ) : null}
                        {this.state.proxyService === "Ngrok" && (this.state.ngrokKey ?? "").length > 0 ? (
                            <span>
                                <div>
                                    <h3 className="aSettingTitle">Ngrok Protocol:</h3>
                                    <p className="settingsHelp">
                                        Select the protocol you want to use for the Ngrok tunnel. This defaults to
                                        &quot;HTTP&quot;, but if you are having issues, you can try &quot;TCP&quot;. An
                                        Ngrok Auth Token is required to use TCP.
                                    </p>
                                </div>
                                <select value={this.state.ngrokProtocol} onChange={e => this.handleProtocolChange(e)}>
                                    <option value="http">HTTP</option>
                                    <option value="tcp">TCP</option>
                                </select>
                            </span>
                        ) : null}
                        <div className="aCheckboxDiv">
                            <div>
                                <h3 className="aSettingTitle">Enable Private API Features</h3>
                                <p className="settingsHelp">
                                    If you have set up the Private API features (via MacForge or MySIMBL), enable this
                                    option to allow the server to communicate with the iMessage Private API.
                                </p>
                            </div>
                            <label className="form-switch">
                                <input
                                    id="togglePrivateApi"
                                    onChange={e => this.handleInputChange(e)}
                                    type="checkbox"
                                    checked={this.state.enablePrivateApi}
                                />
                                <i />
                            </label>
                        </div>
                        <div className="aCheckboxDiv">
                            <div>
                                <h3 className="aSettingTitle">Keep MacOS Awake</h3>
                                <p className="settingsHelp">
                                    When enabled, you mac will not fall asleep due to inactivity, with the caveat of
                                    when you close your laptop
                                </p>
                            </div>
                            <label className="form-switch">
                                <input
                                    id="toggleCaffeinate"
                                    onChange={e => this.handleInputChange(e)}
                                    type="checkbox"
                                    checked={this.state.autoCaffeinate}
                                />
                                <i />
                            </label>
                        </div>
                        <div className="aCheckboxDiv">
                            <div>
                                <h3 className="aSettingTitle">Startup With MacOS</h3>
                                <p className="settingsHelp">
                                    When enabled, BlueBubbles will start automatically when you login.
                                </p>
                            </div>
                            <label className="form-switch">
                                <input
                                    id="toggleAutoStart"
                                    onChange={e => this.handleInputChange(e)}
                                    type="checkbox"
                                    checked={this.state.autoStart}
                                />
                                <i />
                            </label>
                        </div>
                        <div className="aCheckboxDiv">
                            <div>
                                <h3 className="aSettingTitle">Check for Updates on Startup</h3>
                                <p className="settingsHelp">
                                    When enabled, BlueBubbles will automatically check for updates on startup
                                </p>
                            </div>
                            <label className="form-switch">
                                <input
                                    id="toggleCheckForUpdates"
                                    onChange={e => this.handleInputChange(e)}
                                    type="checkbox"
                                    checked={this.state.checkForUpdates}
                                />
                                <i />
                            </label>
                        </div>
                        <div className="aCheckboxDiv">
                            <div>
                                <h3 className="aSettingTitle">Auto Install/Apply Updates</h3>
                                <p className="settingsHelp">
                                    When enabled, BlueBubbles will auto-install the latest available version when an
                                    update is detected
                                </p>
                            </div>
                            <label className="form-switch">
                                <input
                                    id="toggleAutoInstallUpdates"
                                    onChange={e => this.handleInputChange(e)}
                                    type="checkbox"
                                    checked={this.state.autoInstallUpdates}
                                />
                                <i />
                            </label>
                        </div>
                        <div className="aCheckboxDiv">
                            <div>
                                <h3 className="aSettingTitle">Hide Dock Icon</h3>
                                <p className="settingsHelp">
                                    Hiding the dock icon will not close the app. You can open the app again via the
                                    status bar icon.
                                </p>
                            </div>
                            <label className="form-switch">
                                <input
                                    id="toggleDockIcon"
                                    onChange={e => this.handleInputChange(e)}
                                    type="checkbox"
                                    checked={this.state.hideDockIcon}
                                />
                                <i />
                            </label>
                        </div>
                        <div className="aCheckboxDiv">
                            <div>
                                <h3 className="aSettingTitle">Always Start via Terminal</h3>
                                <p className="settingsHelp">
                                    When BlueBubbles starts up, it will auto-reload itself in terminal mode. When in
                                    terminal, type `help` for command information.
                                </p>
                            </div>
                            <label className="form-switch">
                                <input
                                    id="toggleTerminalStart"
                                    onChange={e => this.handleInputChange(e)}
                                    type="checkbox"
                                    checked={this.state.startViaTerminal}
                                />
                                <i />
                            </label>
                        </div>
                        <h3 className="largeSettingTitle">Google FCM Configurations</h3>
                        <h3 className="aSettingTitle">
                            Server Config Status:{" "}
                            <p id="serverConfigStatus">{this.state.fcmServer ? "Loaded" : "Not Set"}</p>
                        </h3>
                        <br />
                        <Dropzone onDrop={acceptedFiles => this.handleServerFile(acceptedFiles)}>
                            {({ getRootProps, getInputProps }) => (
                                <section id="fcmClientDrop-Set">
                                    <div {...getRootProps()}>
                                        <input {...getInputProps()} />
                                        <p>
                                            {this.state.fcmServer
                                                ? "FCM Client Configuration Successfully Loaded"
                                                : "Drag or click to upload FCM Server"}
                                        </p>
                                    </div>
                                </section>
                            )}
                        </Dropzone>
                        <br />
                        <h3 className="aSettingTitle">
                            Client Config Status:{" "}
                            <p id="clientConfigStatus">{this.state.fcmClient ? "Loaded" : "Not Set"}</p>
                        </h3>
                        <br />
                        <Dropzone onDrop={acceptedFiles => this.handleClientFile(acceptedFiles)}>
                            {({ getRootProps, getInputProps }) => (
                                <section id="fcmServerDrop-Set">
                                    <div {...getRootProps()}>
                                        <input {...getInputProps()} />
                                        <p>
                                            {this.state.fcmClient
                                                ? "FCM Service Configuration Successfully Loaded"
                                                : "Drag or click to upload FCM Client (google-services.json)"}
                                        </p>
                                    </div>
                                </section>
                            )}
                        </Dropzone>
                    </div>
                </div>

                <div id="myModal" className="modal" style={{ display: this.state.showModal ? "block" : "none" }}>
                    <div className="modal-content">
                        <div className="modal-header">
                            <span
                                id="modalCloseBtn"
                                role="button"
                                className="close"
                                onClick={() => this.saveCustomServerUrl(false)}
                                onKeyDown={() => this.saveCustomServerUrl(false)}
                                tabIndex={0}
                            >
                                &times;
                            </span>
                            <h2>Enter your server&rsquo;s host name and port</h2>
                        </div>
                        <div className="modal-body">
                            <div className="modal-col">
                                <input
                                    id="serverUrl"
                                    className="aInput"
                                    value={this.state.serverUrl}
                                    onChange={e => this.handleInputChange(e)}
                                />
                                <button className="modal-button" onClick={() => this.saveCustomServerUrl(true)}>
                                    Save
                                </button>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        );
    }
}

export default SettingsView;
