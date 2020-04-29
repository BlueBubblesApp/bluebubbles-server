/* eslint-disable */
import * as React from "react";
import { ipcRenderer } from "electron";

import {
    createStyles,
    Theme,
    withStyles,
    StyleRules
} from "@material-ui/core/styles";

import Dropzone from "react-dropzone";
import { GetApp } from "@material-ui/icons";
import { Typography } from "@material-ui/core";

import AndroidIconImage from "@renderer/assets/img/android-icon.png";


interface Props {
    classes: any;
}

interface State {
    fcmClient: any
}

class FCMClient extends React.Component<Props, State> {
    state: State = {
        fcmClient: null
    };

    handleClientFile = (acceptedFiles: any) => {
        const reader = new FileReader();

        reader.onabort = () => console.log("file reading was aborted");
        reader.onerror = () => console.log("file reading has failed");
        reader.onload = () => {
            // Do whatever you want with the file contents
            const binaryStr = reader.result;
            ipcRenderer.invoke(
                "set-fcm-client",
                JSON.parse(binaryStr as string)
            );
            this.setState({ fcmClient: binaryStr });
        };

        reader.readAsText(acceptedFiles[0]);
    };

    render() {
        const { classes } = this.props;

        return (
            <section className={classes.root}>
                <Typography variant="h4" className={classes.header}>
                    Google FCM Client
                </Typography>
                <Typography variant="subtitle2" className={classes.subtitle}>
                    This is a continuoution of the previous step. Basically, in
                    the previous step, we loaded the FCM service for the server.
                    Now we need to load the FCM service for the client. This
                    way, we can easily provide your phone with the configuration
                    via a QRCode.
                </Typography>
                <br />
                <Typography variant="subtitle2" className={classes.subtitle}>
                    <strong>1.</strong> In your Firebase console, head back to
                    your Project Overview
                </Typography>
                <Typography variant="subtitle2" className={classes.subtitle}>
                    <strong>2.</strong> On that page, there should be a block of
                    text asking you to get started with your project. There will
                    be a row of icons below it. Click on the Android Icon
                </Typography>
                <img src={AndroidIconImage} alt="" />
                <Typography variant="subtitle2" className={classes.subtitle}>
                    <strong>3.</strong> You will be prompted to fill out some
                    information about your App. For the package name, enter in
                    something similar to "com.{"<your_name>"}.bluebubbles". For
                    the App nickname, just enter "BlueBubbles App"
                </Typography>
                <Typography variant="subtitle2" className={classes.subtitle}>
                    <strong>4.</strong> Register your app, then download the
                    "google-services.json" configuration file. Once downloaded,
                    you can close out of your Firebase Console.
                </Typography>
                <Typography variant="subtitle2" className={classes.subtitle}>
                    <strong>5.</strong> In the dropzone below, select your
                    recently downloaded "google-services.json" file.
                </Typography>
                <Dropzone
                    onDrop={(acceptedFiles) =>
                        this.handleClientFile(acceptedFiles)
                    }
                >
                    {({ getRootProps, getInputProps }) => (
                        <section
                            {...getRootProps()}
                            className={classes.dropzone}
                        >
                            <input {...getInputProps()}></input>
                            <GetApp />
                            <span className={classes.dzText}>
                                {this.state.fcmClient
                                    ? "FCM Client Configuration Successfully Loaded"
                                    : "Drag 'n' drop or click here to load your FCM client configuration"}
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

export default withStyles(styles)(FCMClient);
