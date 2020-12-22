/* eslint-disable jsx-a11y/label-has-associated-control */
/* eslint-disable react/sort-comp */
/* eslint-disable react/no-unused-state */
/* eslint-disable jsx-a11y/click-events-have-key-events */
/* eslint-disable jsx-a11y/no-static-element-interactions */
/* eslint-disable jsx-a11y/anchor-is-valid */
/* eslint-disable class-methods-use-this */
/* eslint-disable max-len */
/* eslint-disable react/prefer-stateless-function */
import * as React from "react";
import Dropzone from "react-dropzone";
import { shell, ipcRenderer } from "electron";
import { Redirect } from "react-router";
import { isValidServerConfig, isValidClientConfig, checkFirebaseUrl, invokeMain } from "@renderer/helpers/utils";
import "./PreDashboardView.css";
import { Config } from "@server/databases/server/entity";

interface State {
    config: Config;
    port?: string;
    abPerms: string;
    fdPerms: string;
    fcmServer: any;
    fcmClient: any;
    redirect: any;
    inputPassword: string;
    enableNgrok: boolean;
    showModal: boolean;
    serverUrl: string;
    smsSupport: boolean;
    showUpdateToast: boolean;
    checkForUpdates: boolean;
    autoInstallUpdates: boolean;
}

class PreDashboardView extends React.Component<unknown, State> {
    backgroundPermissionsCheck: NodeJS.Timeout;

    constructor(props: unknown) {
        super(props);

        this.state = {
            config: null,
            abPerms: "deauthorized",
            fdPerms: "deauthorized",
            fcmServer: null,
            fcmClient: null,
            redirect: null,
            inputPassword: "",
            enableNgrok: true,
            showModal: false,
            serverUrl: "",
            smsSupport: false,
            showUpdateToast: true,
            checkForUpdates: true,
            autoInstallUpdates: false
        };
    }

    async componentDidMount() {
        this.checkPermissions();
        const currentTheme = await ipcRenderer.invoke("get-current-theme");

        await this.setTheme(currentTheme.currentTheme);

        try {
            const config = await ipcRenderer.invoke("get-config");
            if (config) this.setState({ config });
            if (config.tutorial_is_done === true) {
                this.setState({ redirect: "/dashboard" });
            }

            this.setState({ enableNgrok: config.enable_ngrok });
            const ngrokCheckbox: HTMLInputElement = document.getElementById("toggleNgrok") as HTMLInputElement;
            ngrokCheckbox.checked = config.enable_ngrok;
        } catch (ex) {
            console.log("Failed to load database config");
        }

        ipcRenderer.on("config-update", (event, arg) => {
            this.setState({ config: arg });
        });

        this.backgroundPermissionsCheck = setInterval(() => {
            this.checkPermissions();
        }, 5000);
    }

    componentWillUnmount() {
        ipcRenderer.removeAllListeners("config-update");
        clearInterval(this.backgroundPermissionsCheck);
    }

    saveCustomServerUrl = (save: boolean) => {
        if (save) {
            ipcRenderer.invoke("set-config", {
                server_address: this.state.serverUrl
            });
        }

        this.setState({ showModal: false });
    };

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

    openPermissionPrompt = async () => {
        const res = await ipcRenderer.invoke("open_perms_prompt");
    };

    openAccessibilityPrompt = async () => {
        const res = await ipcRenderer.invoke("prompt_accessibility_perms");
    };

    checkPermissions = async () => {
        const res = await ipcRenderer.invoke("check_perms");
        this.setState({
            abPerms: res.abPerms,
            fdPerms: res.fdPerms
        });
    };

    promptAccessibility = async () => {
        const res = await ipcRenderer.invoke("prompt_accessibility");
        this.setState({
            abPerms: res.abPerms
        });
    };

    promptDiskAccess = async () => {
        const res = await ipcRenderer.invoke("prompt_disk_access");
        this.setState({
            fdPerms: res.fdPerms
        });
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
                ipcRenderer.invoke("set-fcm-server", JSON.parse(binaryStr as string));
                this.setState({ fcmServer: binaryStr });
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

    openTutorialLink() {
        shell.openExternal("https://bluebubbles.app/install");
    }

    completeTutorial() {
        ipcRenderer.invoke("toggle-tutorial", true);
        this.setState({ redirect: "/dashboard" });
    }

    handleInputChange = async (e: React.ChangeEvent<HTMLInputElement>) => {
        this.setState({ [e.target.name]: e.target.value } as any);
    };

    handleCheckboxChange(e: React.ChangeEvent<HTMLInputElement>, stateVar: string) {
        this.setState({ [stateVar]: e.target.checked } as any);

        if (e.target.id === "toggleNgrok") {
            ipcRenderer.invoke("toggle-ngrok", e.target.checked);

            if (!e.target.checked) {
                this.setState({ showModal: true });
            }
        } else {
            ipcRenderer.invoke("set-config", {
                [e.target.id]: e.target.checked
            });
        }
    }

    savePassword = async () => {
        await ipcRenderer.invoke("set-config", {
            password: this.state.inputPassword
        });

        if (
            this.state.abPerms === "authorized" &&
            this.state.fdPerms === "authorized" &&
            this.state.fcmClient &&
            this.state.fcmServer &&
            this.state.inputPassword.length > 0
        ) {
            this.completeTutorial();
        }
    };

    getSkipBtn() {
        const output = (str: string) => {
            return <button onClick={() => this.completeTutorial()}>{str}</button>;
        };

        if (!this.state.inputPassword) return null;
        if (this.state.enableNgrok && (!this.state.fcmClient || !this.state.fcmServer)) return output("Skip FCM Setup");
        if (!this.state.enableNgrok && this.state.fcmClient && this.state.fcmServer) return output("Skip Ngrok Setup");
        if (!this.state.enableNgrok && (!this.state.fcmClient || !this.state.fcmServer))
            return output("Skip FCM and Ngrok Setup");
        if (this.state.fcmClient && this.state.fcmServer && this.state.abPerms === "authorized")
            return output("Continue");

        return null;
    }

    render() {
        if (this.state.redirect) {
            return <Redirect to={this.state.redirect} />;
        }
        let fdPermStyles = {
            color: "red"
        };

        let abPermStyles = {
            color: "red"
        };

        if (this.state.fdPerms === "authorized") {
            fdPermStyles = {
                color: "green"
            };
        }

        if (this.state.abPerms === "authorized") {
            abPermStyles = {
                color: "green"
            };
        }

        return (
            <div id="PreDashboardView" data-theme="light">
                <div id="welcomeOverlay">
                    <h1>Welcome</h1>
                </div>
                <div id="predashboardContainer">
                    <p id="introText">
                        Thank you downloading BlueBubbles! In order to get started, follow the instructions outlined in{" "}
                        <a onClick={() => this.openTutorialLink()} style={{ color: "#147EFB", cursor: "pointer" }}>
                            our installation tutorial
                        </a>
                        .
                    </p>
                    <div id="permissionStatusContainer">
                        <h1>Required App Permissions</h1>
                        <div className="permissionTitleContainer">
                            <h3 className="permissionTitle">Full Disk Access:</h3>
                            <h3 className="permissionStatus" style={fdPermStyles}>
                                {this.state.fdPerms === "authorized" ? "Enabled" : "Disabled"}
                            </h3>
                            {this.state.fdPerms === "authorized" ? null : (
                                <button className="recheckPermissionButton" onClick={() => this.promptDiskAccess()}>
                                    Temporarily Fake Enabled
                                </button>
                            )}
                        </div>
                        <div className="permissionTitleContainer">
                            <h3 className="permissionTitle">Full Accessibility Access:</h3>
                            <h3 className="permissionStatus" style={abPermStyles}>
                                {this.state.abPerms === "authorized" ? "Enabled" : "Disabled"}
                            </h3>
                            {this.state.abPerms === "authorized" ? null : (
                                <button className="recheckPermissionButton" onClick={() => this.promptAccessibility()}>
                                    Prompt For Access
                                </button>
                            )}
                        </div>
                    </div>
                    <div id="requiredServerSettingsContainer">
                        <h1>Required Server Settings</h1>
                        <div id="setPasswordContainer">
                            <h3>Server Password:</h3>
                            <input
                                id="requiredPasswordInput"
                                placeholder="Enter a password"
                                name="inputPassword"
                                value={this.state.inputPassword}
                                onChange={e => this.handleInputChange(e)}
                                onBlur={() => this.savePassword()}
                            />
                        </div>
                        <div id="setNgrokContainer">
                            <h3>Enable NGROK: </h3>
                            <div style={{ marginTop: "3px" }}>
                                <input
                                    id="toggleNgrok"
                                    checked={this.state.enableNgrok}
                                    onChange={e => this.handleCheckboxChange(e, "enableNgrok")}
                                    type="checkbox"
                                />
                                <i />
                            </div>
                        </div>
                        <div id="setNgrokContainer">
                            <h3>Check for Updates on Startup: </h3>
                            <div style={{ marginTop: "3px" }}>
                                <input
                                    id="check_for_updates"
                                    checked={this.state.checkForUpdates}
                                    onChange={e => this.handleCheckboxChange(e, "checkForUpdates")}
                                    type="checkbox"
                                />
                                <i />
                            </div>
                        </div>
                        <div id="setNgrokContainer">
                            <h3>Auto Install/Apply Updates: </h3>
                            <div style={{ marginTop: "3px" }}>
                                <input
                                    id="auto_install_updates"
                                    checked={this.state.autoInstallUpdates}
                                    onChange={e => this.handleCheckboxChange(e, "autoInstallUpdates")}
                                    type="checkbox"
                                />
                                <i />
                            </div>
                        </div>
                        <div id="setNgrokContainer">
                            <h3>SMS Support (Desktop Client): </h3>
                            <div style={{ marginTop: "3px" }}>
                                <input
                                    id="sms_support"
                                    checked={this.state.smsSupport}
                                    onChange={e => this.handleCheckboxChange(e, "smsSupport")}
                                    type="checkbox"
                                />
                                <i />
                            </div>
                        </div>
                    </div>
                    <h1 id="uploadTitle">Required Config Files</h1>
                    <Dropzone onDrop={acceptedFiles => this.handleServerFile(acceptedFiles)}>
                        {({ getRootProps, getInputProps }) => (
                            <section id="fcmClientDrop">
                                <div {...getRootProps()}>
                                    <input {...getInputProps()} />
                                    <p>
                                        {this.state.fcmServer
                                            ? "FCM Server Configuration Successfully Loaded"
                                            : "Drag or click to upload FCM Server"}
                                    </p>
                                </div>
                            </section>
                        )}
                    </Dropzone>
                    <Dropzone onDrop={acceptedFiles => this.handleClientFile(acceptedFiles)}>
                        {({ getRootProps, getInputProps }) => (
                            <section id="fcmServerDrop">
                                <div {...getRootProps()}>
                                    <input {...getInputProps()} />
                                    <p>
                                        {this.state.fcmClient
                                            ? "FCM Client Configuration Successfully Loaded"
                                            : "Drag or click to upload FCM Client (google-services.json)"}
                                    </p>
                                </div>
                            </section>
                        )}
                    </Dropzone>
                    <div id="skipDiv">{this.getSkipBtn()}</div>
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
                                    name="serverUrl"
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

export default PreDashboardView;
