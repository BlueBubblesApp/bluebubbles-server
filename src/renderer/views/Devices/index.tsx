/* eslint-disable */
import * as React from "react";
import { ipcRenderer } from "electron";

import {
    createStyles,
    Theme,
    withStyles,
    StyleRules
} from "@material-ui/core/styles";

import {
    TextField,
    LinearProgress,
    Typography,
    Button,
    IconButton,
    TableContainer,
    Paper,
    Table,
    TableHead,
    TableRow,
    TableCell,
    TableBody
} from "@material-ui/core";

interface Props {
    classes: any
}

interface State {
    devices: any[];
}

class Devices extends React.Component<Props, State> {
    state: State = {
        devices: []
    }

    async componentDidMount() {
        await this.refreshDevices();
    }

    async refreshDevices() {
        this.setState({
            devices: await ipcRenderer.invoke("get-devices")
        });
    }

    render() {
        const { classes } = this.props;
        const { devices } = this.state;

        return (
            <section className={classes.root}>
                <Typography variant="h3" className={classes.header}>
                    Linked Devices
                </Typography>
                <TableContainer component={Paper}>
                    <Table className={classes.table} aria-label="simple table">
                        <TableHead>
                            <TableRow>
                                <TableCell>Device Name</TableCell>
                                <TableCell align="right">Identifier</TableCell>
                            </TableRow>
                        </TableHead>
                        <TableBody>
                            {devices.map((row) => (
                                <TableRow key={row.identifier}>
                                    <TableCell component="th" scope="row">
                                        {row.name || "N/A"}
                                    </TableCell>
                                    <TableCell align="right">
                                        {row.identifier}
                                    </TableCell>
                                </TableRow>
                            ))}
                        </TableBody>
                    </Table>
                    {devices.length === 0 ? (
                        <p style={{ textAlign: "center" }}>No devices registered!</p>
                    ) : null}
                </TableContainer>
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
        }
    });

export default withStyles(styles)(Devices);
