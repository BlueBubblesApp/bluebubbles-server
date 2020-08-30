/* eslint-disable jsx-a11y/label-has-associated-control */
/* eslint-disable max-len */
/* eslint-disable react/no-unused-state */
/* eslint-disable react/prefer-stateless-function */
import * as React from "react";
import { ipcRenderer } from "electron";
import Dropzone from "react-dropzone";
import { isValidServerConfig, isValidClientConfig } from "@renderer/helpers/utils";
import "./SettingsView.css";
import TopNav from "./TopNav/TopNav";
import LeftStatusIndicator from "../DashboardView/LeftStatusIndicator/LeftStatusIndicator";

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
            ngrokKey: ""
        };

        this.handleInputChange = this.handleInputChange.bind(this);
    }

    async componentDidMount() {
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
                ngrokKey: config.ngrok_key
            });
        console.log(config);
        console.log(this.state);
        this.getCaffeinateStatus();

        const client = await ipcRenderer.invoke("get-fcm-client");
        if (client) this.setState({ fcmClient: JSON.stringify(client) });
        const server = await ipcRenderer.invoke("get-fcm-server");
        if (server) this.setState({ fcmServer: JSON.stringify(server) });

        const toggleCaffeinate: HTMLInputElement = document.getElementById("toggleCaffeinate") as HTMLInputElement;
        const toggleAutoStart: HTMLInputElement = document.getElementById("toggleAutoStart") as HTMLInputElement;

        if (this.state.autoCaffeinate) {
            toggleCaffeinate.checked = true;
        } else {
            toggleCaffeinate.checked = false;
        }

        if (this.state.autoStart) {
            toggleAutoStart.checked = true;
        } else {
            toggleAutoStart.checked = false;
        }

        ipcRenderer.on("config-update", (event, arg) => {
            this.setState({ config: arg });
        });
    }

    componentWillUnmount() {
        ipcRenderer.removeAllListeners("config-update");
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

    handleInputChange = async (e: any) => {
        // eslint-disable-next-line prefer-destructuring
        const id = e.target.id;
        if (["serverPort", "serverPassword", "ngrokKey"].includes(id)) {
            this.setState({ [id]: e.target.value } as any);
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

        console.log(this.state);
    };

    saveConfig = async () => {
        await ipcRenderer.invoke("set-config", {
            socket_port: this.state.serverPort,
            password: this.state.serverPassword,
            ngrok_key: this.state.ngrokKey
        });

        console.log("saved config");
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

    render() {
        return (
            <div id="SettingsView">
                <TopNav />
                <div id="settingsLowerContainer">
                    <LeftStatusIndicator />
                    <div id="settingsMainRightContainer">
                        <h3 className="aSettingTitle">Server Address:</h3>
                        <input
                            readOnly
                            className="aInput"
                            value={this.state.config ? this.state.config.server_address : ""}
                        />
                        <h3 className="aSettingTitle">Server Port:</h3>
                        <input
                            id="serverPort"
                            className="aInput"
                            value={this.state.serverPort}
                            onChange={e => this.handleInputChange(e)}
                            onBlur={() => this.saveConfig()}
                        />
                        <h3 className="aSettingTitle">Server Password:</h3>
                        <input
                            id="serverPassword"
                            className="aInput"
                            value={this.state.serverPassword}
                            onChange={e => this.handleInputChange(e)}
                            onBlur={() => this.saveConfig()}
                        />
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
                            <h3 className="aSettingTitle">Keep MacOS Awake</h3>
                            <label className="form-switch">
                                <input
                                    id="toggleCaffeinate"
                                    onChange={e => this.handleInputChange(e)}
                                    type="checkbox"
                                />
                                <i />
                            </label>
                        </div>
                        <div className="aCheckboxDiv">
                            <h3 className="aSettingTitle">Startup With MacOS</h3>
                            <label className="form-switch">
                                <input id="toggleAutoStart" onChange={e => this.handleInputChange(e)} type="checkbox" />
                                <i />
                            </label>
                        </div>
                        <h3 id="fcmTitle">Google FCM Configurations</h3>
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
            </div>
        );
    }
}

export default SettingsView;
