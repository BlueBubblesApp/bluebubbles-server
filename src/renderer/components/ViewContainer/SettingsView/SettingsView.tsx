/* eslint-disable react/no-array-index-key */
/* eslint-disable class-methods-use-this */
/* eslint-disable jsx-a11y/label-has-associated-control */
/* eslint-disable max-len */
/* eslint-disable react/no-unused-state */
/* eslint-disable react/prefer-stateless-function */
import * as React from "react";
import { ipcRenderer, dialog } from "electron";
import Dropzone from "react-dropzone";
import { isValidServerConfig, isValidClientConfig } from "@renderer/helpers/utils";
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
    enableNgrok: boolean;
    showModal: boolean;
    serverUrl: string;
    encryptComs: boolean;
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
            ngrokKey: "",
            enableNgrok: false,
            showModal: false,
            serverUrl: "",
            encryptComs: false
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
                ngrokKey: config.ngrok_key,
                enableNgrok: config.enable_ngrok,
                encryptComs: config.encrypt_coms
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
            if (!valid) return;

            ipcRenderer.invoke("set-fcm-client", JSON.parse(binaryStr as string));
            this.setState({ fcmClient: binaryStr });
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
            if (!valid) return;

            ipcRenderer.invoke("set-fcm-server", JSON.parse(binaryStr as string));
            this.setState({ fcmServer: binaryStr });
        };

        reader.readAsText(acceptedFiles[0]);
    };

    invokeMain(event: string, args: any) {
        ipcRenderer.invoke(event, args);
    }

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

                        {/* <div className="aCheckboxDiv firstCheckBox">
                            <h3 className="aSettingTitle">Encrypt Communications</h3>
                            <label className="form-switch">
                                <input
                                    id="toggleEncrypt"
                                    onChange={e => this.handleInputChange(e)}
                                    type="checkbox"
                                    checked={this.state.encryptComs}
                                />
                                <i />
                            </label>
                        </div> */}

                        <h3 className="aSettingTitle">Ngrok API Key (optional):</h3>
                        <input
                            id="ngrokKey"
                            className="aInput"
                            placeholder="No key uploaded"
                            value={this.state.ngrokKey}
                            onChange={e => this.handleInputChange(e)}
                            onBlur={() => this.saveConfig()}
                        />
                        <div className="aCheckboxDiv firstCheckBox">
                            <h3 className="aSettingTitle">Enable Ngrok</h3>
                            <label className="form-switch">
                                <input
                                    id="toggleNgrok"
                                    onChange={e => this.handleInputChange(e)}
                                    type="checkbox"
                                    checked={this.state.enableNgrok}
                                />
                                <i />
                            </label>
                        </div>
                        <div className="aCheckboxDiv">
                            <h3 className="aSettingTitle">Keep MacOS Awake</h3>
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
                            <h3 className="aSettingTitle">Startup With MacOS</h3>
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
                        <h3 className="largeSettingTitle">Google FCM Configurations</h3>
                        <h3 className="aSettingTitle">
                            Server Config Status:{" "}
                            <p id="serverConfigStatus">{this.state.fcmServer ? "Loaded" : "Not Set"}</p>
                        </h3>
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
                        <h3 className="aSettingTitle">
                            Client Config Status:{" "}
                            <p id="clientConfigStatus">{this.state.fcmClient ? "Loaded" : "Not Set"}</p>
                        </h3>
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
                                role="button"
                                className="close"
                                onClick={() => this.saveCustomServerUrl(false)}
                                onKeyDown={() => this.saveCustomServerUrl(false)}
                                tabIndex={0}
                            >
                                &times;
                            </span>
                            <h2>Enter your server&rsquo;s host name</h2>
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
