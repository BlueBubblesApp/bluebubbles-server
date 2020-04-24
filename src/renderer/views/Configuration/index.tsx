/* eslint-disable */
import * as React from "react";
import { ipcRenderer } from "electron";

import {
    createStyles,
    Theme,
    withStyles,
    StyleRules
} from "@material-ui/core/styles";
import { Typography, Button } from "@material-ui/core";

import { Config } from "@renderer/variables/types";
import { TextField, LinearProgress } from "@material-ui/core";

import Dropzone from "react-dropzone";
import * as QRCode from "qrcode.react";

interface Props {
    config: Config
    classes: any;
}

interface State {
    port: string;
    frequency: string;
    fcmClient: any;
    fcmServer: any
}

class Dashboard extends React.Component<Props, State> {
    state: State = {
        port: String(this.props.config?.socket_port || ""),
        frequency: String(this.props.config?.poll_frequency || ""),
        fcmClient: null,
        fcmServer: null
    }

    componentWillReceiveProps(nextProps: Props) {
        this.setState({
            port: String(nextProps.config?.socket_port || ""),
            frequency: String(nextProps.config?.poll_frequency || "")
        });
    }

    async componentDidMount() {
        var fcmClientData = await ipcRenderer.invoke("get-fcm-client");
        // fcmClientData.push(config?.server_address);
        this.setState({
            fcmClient: JSON.stringify(fcmClientData),
            fcmServer: JSON.stringify(await ipcRenderer.invoke("get-fcm-server"))
        })
    }

    saveConfig = async () => {
        console.log("sending...")
        const res = await ipcRenderer.invoke("set-config", {
            poll_frequency: this.state.frequency,
            socket_port: this.state.port
        });
        console.log(res)
    }

    handleChange = (e: React.ChangeEvent<HTMLTextAreaElement | HTMLInputElement>) => {
        const id = e.target.id;
        if (id === "port") this.setState({ port: e.target.value });
        if (id === "frequency") this.setState({ frequency: e.target.value });
    }

    handleClientFile = (acceptedFiles: any) => {
        const reader = new FileReader();

        reader.onabort = () => console.log("file reading was aborted");
        reader.onerror = () => console.log("file reading has failed");
        reader.onload = async () => {
            // Do whatever you want with the file contents
            const binaryStr = reader.result;
            ipcRenderer.invoke("set-fcm-client", JSON.parse(binaryStr as string));
            //this is def not the correct way to do it but i just need to test, sowwy
            this.setState({ fcmClient: JSON.stringify(await ipcRenderer.invoke("get-fcm-client")), });
        };

        reader.readAsText(acceptedFiles[0]);
    }

    handleServerFile = (acceptedFiles: any) => {
        const reader = new FileReader();

        reader.onabort = () => console.log("file reading was aborted");
        reader.onerror = () => console.log("file reading has failed");
        reader.onload = () => {
            // Do whatever you want with the file contents
            const binaryStr = reader.result;
            ipcRenderer.invoke("set-fcm-server", JSON.parse(binaryStr as string));
            this.setState({ fcmServer: binaryStr });
        };

        reader.readAsText(acceptedFiles[0]);
    }

    render() {
        const { classes, config } = this.props;
        console.log(config)

        return (
            <section className={classes.root}>
                <Typography variant="h3" className={classes.header}>
                    Configuration
                </Typography>

                {!config ? (
                    <LinearProgress />
                ) : (
                        <form
                            className={classes.form}
                            noValidate
                            autoComplete="off"
                        >
                            <TextField
                                required
                                className={classes.field}
                                id="server-address"
                                label="Current Server Address"
                                variant="outlined"
                                value={config?.server_address}
                                disabled
                            />
                            <TextField
                                required
                                className={classes.field}
                                id="port"
                                label="Socket Port"
                                variant="outlined"
                                value={this.state.port}
                                onChange={(e) => this.handleChange(e)}
                            />
                            <TextField
                                required
                                id="frequency"
                                className={classes.field}
                                label="Poll Frequency (ms)"
                                value={this.state.frequency}
                                variant="outlined"
                                helperText="How often should we check for new messages?"
                                onChange={(e) => this.handleChange(e)}
                            />
                            <section className={classes.fcmConfig}>
                                <section>
                                    <Typography
                                        variant="h5"
                                        className={classes.header}
                                    >
                                        Google FCM Configurations
                                </Typography>
                                    <Typography
                                        variant="subtitle1"
                                        className={classes.header}
                                    >
                                        Service Config Status:{" "}
                                        {this.state.fcmServer
                                            ? "Loaded"
                                            : "Not Set"}
                                    </Typography>
                                    <Dropzone
                                        onDrop={(acceptedFiles) =>
                                            this.handleServerFile(acceptedFiles)
                                        }
                                    >
                                        {({ getRootProps, getInputProps }) => (
                                            <section className={classes.dropzone}>
                                                <div {...getRootProps()}>
                                                    <input {...getInputProps()} />
                                                    <p className={classes.dzText}>
                                                        Drag 'n' drop or click here
                                                        to load your FCM service
                                                        configuration
                                                </p>
                                                </div>
                                            </section>
                                        )}
                                    </Dropzone>
                                    <br />
                                    <Typography
                                        variant="subtitle1"
                                        className={classes.header}
                                    >
                                        Client Config Status:{" "}
                                        {this.state.fcmClient
                                            ? "Loaded"
                                            : "Not Set"}
                                    </Typography>
                                    <Dropzone
                                        onDrop={(acceptedFiles) =>
                                            this.handleClientFile(acceptedFiles)
                                        }
                                    >
                                        {({ getRootProps, getInputProps }) => (
                                            <section className={classes.dropzone}>
                                                <div {...getRootProps()}>
                                                    <input {...getInputProps()} />
                                                    <p className={classes.dzText}>
                                                        Drag 'n' drop or click here
                                                        to load your FCM client
                                                        configuration
                                                </p>
                                                </div>
                                            </section>
                                        )}
                                    </Dropzone>
                                </section>
                                <section className={classes.qrCode}>
                                    <Typography
                                        variant="subtitle1"
                                        className={classes.header}
                                    >
                                        Client Config QRCode:{" "}
                                        {this.state.fcmClient ? "Valid" : "Invalid"}
                                    </Typography>
                                    <div style={{ padding: "10px 10px 10px 10px", backgroundColor: "white" }}
                                    ><QRCode
                                            size={252}
                                            value={this.state.fcmClient || ""}
                                        /></div>
                                </section>
                            </section>

                            <br />
                            <Button
                                onClick={() => this.saveConfig()}
                                color="secondary"
                            >
                                Save
                        </Button>
                        </form>
                    )}
            </section>
        );
    }
}

const styles = (theme: Theme): StyleRules<string, {}> =>
    createStyles({
        root: {

        },
        header: {
            fontWeight: 300,
            marginBottom: "1em"
        },
        form: {
            display: "flex",
            flexDirection: "column",
            justifyContent: "center"
        },
        field: {
            marginBottom: "1.5em"
        },
        dropzone: {
            border: "1px solid grey",
            borderRadius: "15px",
            padding: "1em"
        },
        dzText: {
            textAlign: "center"
        },
        fcmConfig: {
            display: "flex",
            flexDirection: "row",
            justifyContent: "space-between",
            alignItems: "flex-end"
        },
        qrCode: {
            marginLeft: "1em"
        }
    });

export default withStyles(styles)(Dashboard);
