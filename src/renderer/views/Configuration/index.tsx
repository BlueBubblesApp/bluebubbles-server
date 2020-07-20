/* eslint-disable */
import * as React from "react";
import { ipcRenderer } from "electron";

import { createStyles, Theme, withStyles, StyleRules } from "@material-ui/core/styles";

import { Config } from "@renderer/variables/types";
import {
    TextField,
    LinearProgress,
    Typography,
    Button,
    FormControlLabel,
    Checkbox,
    FormControl,
    InputLabel,
    InputAdornment,
    IconButton,
    OutlinedInput
} from "@material-ui/core";

import { GetApp, Visibility, VisibilityOff } from "@material-ui/icons";

import Dropzone from "react-dropzone";
import * as QRCode from "qrcode.react";

interface Props {
    config: Config;
    classes: any;
}
interface State {
    port: string;
    fcmClient: any;
    fcmServer: any;
    autoCaffeinate: boolean;
    isCaffeinated: boolean;
    autoStart: boolean;
    password: string;
    showPassword: boolean;
}

class Dashboard extends React.Component<Props, State> {
    state: State = {
        port: String(this.props.config?.socket_port ?? ""),
        fcmClient: null,
        fcmServer: null,
        autoCaffeinate: this.props.config?.auto_caffeinate ?? false,
        isCaffeinated: false,
        autoStart: this.props.config?.auto_start ?? false,
        password: this.props.config?.password ?? "",
        showPassword: false
    };

    componentWillReceiveProps(nextProps: Props) {
        this.setState({
            port: String(nextProps.config?.socket_port ?? ""),
            autoStart: nextProps.config?.auto_start,
            autoCaffeinate: nextProps.config?.auto_caffeinate,
            password: nextProps.config?.password ?? this.state.password
        });
    }

    async componentDidMount() {
        const client = await ipcRenderer.invoke("get-fcm-client");
        if (client) this.setState({ fcmClient: JSON.stringify(client) });
        const server = await ipcRenderer.invoke("get-fcm-server");
        if (server) this.setState({ fcmServer: JSON.stringify(server) });
        this.getCaffeinateStatus();
    }

    getCaffeinateStatus = async () => {
        const caffeinateStatus = await ipcRenderer.invoke("get-caffeinate-status");
        this.setState({
            isCaffeinated: caffeinateStatus.isCaffeinated,
            autoCaffeinate: caffeinateStatus.autoCaffeinate
        });
    };

    saveConfig = async () => {
        await ipcRenderer.invoke("set-config", {
            socket_port: this.state.port,
            password: this.state.password
        });
    };

    handleChange = async (e: React.ChangeEvent<HTMLTextAreaElement | HTMLInputElement>) => {
        const id = e.target.id;
        if (id === "port") this.setState({ port: e.target.value });
        if (id === "password") this.setState({ password: e.target.value });
        if (id === "toggleCaffeinate") {
            const target = e.target as HTMLInputElement;
            this.setState({ autoCaffeinate: target.checked });
            await ipcRenderer.invoke("toggle-caffeinate", target.checked);
            await this.getCaffeinateStatus();
        } else if (id === "toggleAutoStart") {
            const target = e.target as HTMLInputElement;
            this.setState({ autoStart: target.checked });
            await ipcRenderer.invoke("toggle-auto-start", target.checked);
        }
    };

    toggleShowPassword = () => {
        this.setState({ showPassword: !this.state.showPassword });
    };

    handleClientFile = (acceptedFiles: any) => {
        const reader = new FileReader();

        reader.onabort = () => console.log("file reading was aborted");
        reader.onerror = () => console.log("file reading has failed");
        reader.onload = () => {
            // Do whatever you want with the file contents
            const binaryStr = reader.result;
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
            ipcRenderer.invoke("set-fcm-server", JSON.parse(binaryStr as string));
            this.setState({ fcmServer: binaryStr });
        };

        reader.readAsText(acceptedFiles[0]);
    };

    buildQrData = (data: string | null): string => {
        if (!data || data.length === 0) return "";

        const jsonData = JSON.parse(data);
        const output = [this.props.config?.password, this.props.config?.server_address || ""];

        output.push(jsonData.project_info.project_id);
        output.push(jsonData.project_info.storage_bucket);
        output.push(jsonData.client[0].api_key[0].current_key);
        output.push(jsonData.project_info.firebase_url);
        const client_id = jsonData.client[0].oauth_client[0].client_id;
        output.push(client_id.substr(0, client_id.indexOf("-")));
        output.push(jsonData.client[0].client_info.mobilesdk_app_id);

        return JSON.stringify(output);
    };

    render() {
        const { classes, config } = this.props;
        const {
            fcmClient,
            port,
            fcmServer,
            autoCaffeinate,
            isCaffeinated,
            autoStart,
            password,
            showPassword
        } = this.state;
        const qrData = this.buildQrData(fcmClient);
        console.log(config);

        let caffeinateString = isCaffeinated ? "Currently caffeinated" : "Not currently caffeinated";

        return (
            <section className={classes.root}>
                <Typography variant="h3" className={classes.header}>
                    Configuration
                </Typography>

                {!config ? (
                    <LinearProgress />
                ) : (
                    <form className={classes.form} noValidate autoComplete="off">
                        <TextField
                            required
                            className={classes.field}
                            id="server-address"
                            label="Current Server Address"
                            variant="outlined"
                            size="small"
                            value={config?.server_address}
                            disabled
                        />
                        <FormControl className={classes.field} size="small" variant="outlined" required>
                            <InputLabel htmlFor="password">Password</InputLabel>
                            <OutlinedInput
                                id="password"
                                label="Password"
                                type={showPassword ? "text" : "password"}
                                value={password}
                                onChange={this.handleChange}
                                endAdornment={
                                    <InputAdornment position="end">
                                        <IconButton
                                            aria-label="toggle password visibility"
                                            onClick={this.toggleShowPassword}
                                            style={{ width: "25px", height: "25px" }}
                                        >
                                            {showPassword ? <Visibility /> : <VisibilityOff />}
                                        </IconButton>
                                    </InputAdornment>
                                }
                            />
                        </FormControl>
                        <TextField
                            required
                            className={classes.field}
                            id="port"
                            label="Socket Port"
                            variant="outlined"
                            size="small"
                            value={port}
                            onChange={this.handleChange}
                        />
                        <FormControlLabel
                            control={
                                <Checkbox
                                    checked={autoCaffeinate}
                                    onChange={this.handleChange}
                                    id="toggleCaffeinate"
                                    name="toggleCaffeinate"
                                    color="primary"
                                    size="small"
                                />
                            }
                            label={`Keep MacOS Awake (${caffeinateString})`}
                        />
                        <FormControlLabel
                            control={
                                <Checkbox
                                    checked={autoStart}
                                    onChange={this.handleChange}
                                    id="toggleAutoStart"
                                    name="toggleAutoStart"
                                    color="primary"
                                    size="small"
                                />
                            }
                            label="Startup with MacOS"
                        />
                        <br />
                        <section className={classes.fcmConfig}>
                            <section>
                                <Typography variant="h5" className={classes.header}>
                                    Google FCM Configurations
                                </Typography>
                                <Typography variant="subtitle1" className={classes.header}>
                                    Service Config Status: {fcmServer ? "Loaded" : "Not Set"}
                                </Typography>
                                <Dropzone onDrop={acceptedFiles => this.handleServerFile(acceptedFiles)}>
                                    {({ getRootProps, getInputProps }) => (
                                        <section {...getRootProps()} className={classes.dropzone}>
                                            <input {...getInputProps()}></input>
                                            <GetApp />
                                            <span className={classes.dzText}>
                                                Drag 'n' drop or click here to load your FCM service configuration
                                            </span>
                                        </section>
                                    )}
                                </Dropzone>
                                <br />
                                <Typography variant="subtitle1" className={classes.header}>
                                    Client Config Status: {fcmClient ? "Loaded" : "Not Set"}
                                </Typography>
                                <Dropzone onDrop={acceptedFiles => this.handleClientFile(acceptedFiles)}>
                                    {({ getRootProps, getInputProps }) => (
                                        <section {...getRootProps()} className={classes.dropzone}>
                                            <input {...getInputProps()}></input>
                                            <GetApp />
                                            <span className={classes.dzText}>
                                                Drag 'n' drop or click here to load your FCM service configuration
                                            </span>
                                        </section>
                                    )}
                                </Dropzone>
                            </section>
                            <section className={classes.qrCode}>
                                <Typography variant="subtitle1" className={classes.header}>
                                    Client Config QRCode: {qrData ? "Valid" : "Invalid"}
                                </Typography>
                                <section className={classes.qrContainer}>
                                    <QRCode size={252} value={qrData} />
                                </section>
                            </section>
                        </section>
                        <br />
                        <Button className={classes.saveBtn} onClick={() => this.saveConfig()} variant="outlined">
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
        root: {},
        header: {
            fontWeight: 400,
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
            borderRadius: "10px",
            padding: "1em",
            display: "flex",
            flexDirection: "column",
            justifyContent: "center",
            alignItems: "center"
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
        },
        qrContainer: {
            padding: "0.5em 0.5em 0.2em 0.5em",
            backgroundColor: "white"
        },
        saveBtn: {
            marginTop: "1em"
        }
    });

export default withStyles(styles)(Dashboard);
