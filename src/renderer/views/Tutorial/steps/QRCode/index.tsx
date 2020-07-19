/* eslint-disable */
import * as React from "react";

import { createStyles, Theme, withStyles, StyleRules } from "@material-ui/core/styles";

import { Typography } from "@material-ui/core";
import * as QRCodeComponent from "qrcode.react";
import { ipcRenderer } from "electron";

interface Props {
    classes: any;
}

interface State {
    config: any;
    fcmClient: string;
}

class QRCode extends React.Component<Props, State> {
    state: State = {
        config: {},
        fcmClient: null
    };

    async componentDidMount() {
        const client = await ipcRenderer.invoke("get-fcm-client");
        console.log(client);
        if (client) this.setState({ fcmClient: JSON.stringify(client) });

        const config = await ipcRenderer.invoke("get-config");
        console.log(config);
        if (config) this.setState({ config });
    }

    buildQrData = (data: string | null): string => {
        if (!data || data.length === 0) return "";

        const jsonData = JSON.parse(data);
        const output = [this.state.config?.password, this.state.config?.server_address || ""];

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
        const { classes } = this.props;
        const qrData = this.buildQrData(this.state.fcmClient);

        return (
            <section className={classes.root}>
                <Typography variant="h4" className={classes.header}>
                    QRCode
                </Typography>
                <Typography variant="subtitle2" className={classes.subtitle}>
                    Now that you've saved your configuration, all that is left to do is load the configuration onto your
                    phone! Below is a QRCode that you can load onto your phone and will auto configure your app to your
                    BlueBubbles Server. Don't worry, if you do not scan now, you can scan it again via the settings page
                    within the server.
                </Typography>
                <br />
                <Typography variant="subtitle2" className={classes.subtitle}>
                    Open your BlueBubbles App and use the built-in QRCode scanner to scan the QRCode below:
                </Typography>
                <br />
                <section className={classes.qrContainer}>
                    <QRCodeComponent size={252} value={qrData} />
                </section>
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
        qrContainer: {
            padding: "0.5em 0.5em 0.2em 0.5em",
            backgroundColor: "white",
            width: "266px"
        }
    });

export default withStyles(styles)(QRCode);
