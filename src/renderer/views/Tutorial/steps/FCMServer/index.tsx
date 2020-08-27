/* eslint-disable */
import * as React from "react";
import { shell, ipcRenderer } from "electron";

import { createStyles, Theme, withStyles, StyleRules } from "@material-ui/core/styles";

import { Typography } from "@material-ui/core";

import ProjectSettingsImage from "@renderer/assets/img/project-settings.png";
import ServiceAccountImage from "@renderer/assets/img/service-account.png";
import Dropzone from "react-dropzone";
import { GetApp } from "@material-ui/icons";
import { isValidServerConfig } from "@renderer/helpers/utils";

interface Props {
    classes: any;
}

interface State {
    fcmServer: any;
}

class FCMServer extends React.Component<Props, State> {
    state: State = {
        fcmServer: null
    };

    openConsole() {
        shell.openExternal("https://console.firebase.google.com/");
    }

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
        const { classes } = this.props;

        return (
            <section className={classes.root}>
                <Typography variant="h4" className={classes.header}>
                    Google FCM Server
                </Typography>
                <Typography variant="subtitle2" className={classes.subtitle}>
                    In order for the server to send notifications and server updates to your Android device, you will
                    need to setup a Google Firebase Account. This way, if your server ever restarts, we can tell your
                    phone that the server is using a new ngrok address. Using Google FCM can also reduce background
                    battery usage, as it will not require a websocket connection at all times.
                </Typography>
                <br />
                <Typography variant="subtitle2" className={classes.subtitle}>
                    <strong>1.</strong> Sign up &amp; login to your Google Account
                </Typography>
                <Typography variant="subtitle2" className={classes.subtitle}>
                    <strong>2.</strong> Access your Firebase console:{" "}
                    <span className={classes.link} onClick={() => this.openConsole()}>
                        Firebase Console
                    </span>
                </Typography>
                <Typography variant="subtitle2" className={classes.subtitle}>
                    <strong>3.</strong> Create a new project called "BlueBubblesApp"
                </Typography>
                <Typography variant="subtitle2" className={classes.subtitle}>
                    <strong>4.</strong> Head into your project settings, then into the "Service Accounts" tab
                </Typography>
                <img src={ProjectSettingsImage} alt="" />
                <br />
                <img src={ServiceAccountImage} alt="" />
                <Typography variant="subtitle2" className={classes.subtitle}>
                    <strong>5.</strong> Download your private key bundle by clicking the "Generate new private key"
                    button
                </Typography>
                <Typography variant="subtitle2" className={classes.subtitle}>
                    <strong>6.</strong> Load your private key bundle here:
                </Typography>
                <Dropzone onDrop={acceptedFiles => this.handleServerFile(acceptedFiles)}>
                    {({ getRootProps, getInputProps }) => (
                        <section {...getRootProps()} className={classes.dropzone}>
                            <input {...getInputProps()}></input>
                            <GetApp />
                            <span className={classes.dzText}>
                                {this.state.fcmServer
                                    ? "FCM Service Configuration Successfully Loaded"
                                    : "Drag 'n' drop or click here to load your FCM service configuration"}
                            </span>
                        </section>
                    )}
                </Dropzone>
            </section>
        );
    }
}

const styles = (theme: Theme): StyleRules<string, {}> =>
    createStyles({
        root: {
            marginTop: "0.5em"
        },
        header: {
            fontWeight: 400
        },
        subtitle: {
            marginTop: "0.5em"
        },
        link: {
            color: "white",
            cursor: "pointer",
            textDecoration: "underline"
        },
        dropzone: {
            marginTop: "1em",
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
        }
    });

export default withStyles(styles)(FCMServer);
