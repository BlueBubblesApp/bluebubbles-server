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
import { isValidServerConfig, isValidClientConfig } from "@renderer/helpers/utils";
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
            inputPassword: ""
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
            if (!valid) return;

            ipcRenderer.invoke("set-fcm-server", JSON.parse(binaryStr as string));
            this.setState({ fcmServer: binaryStr });

            if (
                this.state.abPerms === "authorized" &&
                this.state.fdPerms === "authorized" &&
                this.state.fcmClient &&
                this.state.fcmServer
            ) {
                this.completeTutorial();
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
            if (!valid) return;

            ipcRenderer.invoke("set-fcm-client", JSON.parse(binaryStr as string));
            this.setState({ fcmClient: binaryStr });

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

        reader.readAsText(acceptedFiles[0]);
    };

    openTutorialLink() {
        shell.openExternal("https://bluebubbles.app/install/index.html");
    }

    completeTutorial() {
        ipcRenderer.invoke("toggle-tutorial", true);
        this.setState({ redirect: "/dashboard" });
    }

    handleInputChange = async (e: any) => {
        this.setState({ inputPassword: e.target.value });
    };

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
                                value={this.state.inputPassword}
                                onChange={e => this.handleInputChange(e)}
                                onBlur={() => this.savePassword()}
                            />
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
                </div>
            </div>
        );
    }
}

export default PreDashboardView;
