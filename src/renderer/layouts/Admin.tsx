// React imports
import * as React from "react";
import { Switch, Route, Link } from "react-router-dom";

// Other imports
import clsx from "clsx";
import { ipcRenderer } from "electron";

// Material UI imports
import {
    createStyles,
    Theme,
    withStyles,
    StyleRules,
    createMuiTheme,
    MuiThemeProvider
} from "@material-ui/core/styles";
import ListItem from "@material-ui/core/ListItem";
import ListItemIcon from "@material-ui/core/ListItemIcon";
import ListItemText from "@material-ui/core/ListItemText";
import Drawer from "@material-ui/core/Drawer";
import AppBar from "@material-ui/core/AppBar";
import Toolbar from "@material-ui/core/Toolbar";
import List from "@material-ui/core/List";
import CssBaseline from "@material-ui/core/CssBaseline";
import Typography from "@material-ui/core/Typography";
import Divider from "@material-ui/core/Divider";
import IconButton from "@material-ui/core/IconButton";
import Badge from "@material-ui/core/Badge";
import Menu from "@material-ui/core/Menu";
import MenuItem from "@material-ui/core/MenuItem";

// Material UI Icons
import MenuIcon from "@material-ui/icons/Menu";
import ChevronLeftIcon from "@material-ui/icons/ChevronLeft";
import DeviceIcon from "@material-ui/icons/DeviceHub";
import HomeIcon from "@material-ui/icons/Home";
import SettingsIcon from "@material-ui/icons/Settings";
import LogIcon from "@material-ui/icons/Receipt";
import NotificationsIcon from '@material-ui/icons/Notifications';
import WarningIcon from '@material-ui/icons/Warning';
import InfoIcon from '@material-ui/icons/Help';
import SuccessIcon from '@material-ui/icons/CheckCircle';
import ErrorIcon from '@material-ui/icons/Error';

// Custom Components
import Configuration from "@renderer/views/Configuration";
import Devices from "@renderer/views/Devices";
import Dashboard from "@renderer/views/Dashboard";
import Logs from "@renderer/views/Logs";
import Tutorial from "@renderer/views/Tutorial";

// Helpers
import { Config } from "@renderer/variables/types";

const CustomMuiTheme = createMuiTheme({
    palette: {
        type: "dark"
    }
});

const StyledMenuItem = withStyles(theme => ({
    root: {
        borderBottom: "1px solid grey",
        paddingTop: "5px",
        paddingBottom: "5px",
        '&:first-child': {
            paddingTop: 0
        },
        '&:last-child': {
            borderBottom: 0,
            paddingBottom: 0
        },
        minWidth: "500px"
    }
}))(MenuItem);

const alertIconMap: { [key: string]: JSX.Element } = {
    info: <InfoIcon />,
    warn: <WarningIcon />,
    error: <ErrorIcon />,
    success: <SuccessIcon />
}

interface Props {
    classes: any;
}

interface State {
    open: boolean
    config: Config,
    alerts: any[],
    alertElement: HTMLElement
}

class AdminLayout extends React.Component<Props, State> {
    state: State = {
        open: false,
        config: null,
        alerts: [],
        alertElement: null
    }

    async componentDidMount() {
        try {
            const config = await ipcRenderer.invoke("get-config");
            if (config) this.setState({ config });
            const currentAlerts = await ipcRenderer.invoke("get-alerts");
            if (currentAlerts) this.setState({ alerts: currentAlerts });
        } catch (ex) {
            console.log("Failed to load database config & alerts");
        }

        ipcRenderer.on("config-update", (event, arg) => {
            this.setState({ config: arg })
        })

        ipcRenderer.on("new-alert", (event, arg) => {
            const { alerts } = this.state;

            // Insert at index 0, then concatenate to 10 items
            alerts.splice(0, 0, alert);
            if (alerts.length > 10)
                alerts.slice(0, 10);

            // Set the state
            this.setState({ alerts });
            console.log(alerts);
        })
    }

    handleDrawerOpen = () => {
        this.setState({ open: true });
    };

    handleDrawerClose = () => {
;        this.setState({ open: false });
    };

    handleAlertClose = async () => {
        this.setState({ alertElement: null });
        await ipcRenderer.invoke(
            "mark-alert-as-read", this.state.alerts.filter((item) => !item.isRead).map((item) => item.id));

        // Mark all as read
        const newAlerts = this.state.alerts;
        for (const i of newAlerts)
            i.isRead = true;
        this.setState({ alerts: newAlerts });
    };

    markAlertAsRead = async (id: number) => {
        await ipcRenderer.invoke("mark-alert-as-read", [id]);

        // Mark individual as read
        const newAlerts = this.state.alerts;
        for (const i of newAlerts)
            if (i.id === id)
                i.isRead = true;
        this.setState({ alerts: newAlerts });
    };

    handleAlertOpen = (event: React.MouseEvent<HTMLElement>) => {
        this.setState({ alertElement: event.currentTarget });
    };

    renderAlerts = () => {
        const { classes } = this.props;
        return (
            <Menu
                anchorEl={this.state.alertElement}
                getContentAnchorEl={null}
                elevation={0}
                anchorOrigin={{ vertical: 'bottom', horizontal: 'left' }}
                id='alert-menu'
                keepMounted
                transformOrigin={{ vertical: 'top', horizontal: 'center' }}
                open={Boolean(this.state.alertElement)}
                onClose={() => this.handleAlertClose()}>
                {this.state.alerts.map((item) => {
                    const typeIcon = alertIconMap[item.type];
                    return (
                        <StyledMenuItem key={item.id} onClick={() => this.markAlertAsRead(item.id)}>
                            <section className={classes.alertBlock}>
                                <section className={classes.alertBody}>
                                    <section
                                        style={{ wordBreak: "break-word", whiteSpace: "normal", maxWidth: "425px" }}>
                                            <span>{item.value}</span>
                                    </section>
                                    <span>{typeIcon}</span>
                                </section>
                                <section className={classes.alertFooter}>
                                    <span
                                        style={{ textDecoration: (item.isRead) ? 'none' : 'underline' }}>
                                            {(item.isRead) ? 'Already read' : 'Mark as read'}
                                    </span>
                                    <span>{item.created.toLocaleString()}</span>
                                </section>
                            </section>
                        </StyledMenuItem>
                    );
                })}
            </Menu>
        )
    };

    render() {
        const { classes } = this.props;
        const { open, config, alerts } = this.state;

        return (
            <MuiThemeProvider theme={CustomMuiTheme}>
                <section className={classes.root}>
                    <CssBaseline />
                    <AppBar
                        position="fixed"
                        className={clsx(classes.appBar, {
                            [classes.appBarShift]: open
                        })}>
                        <Toolbar>
                            <IconButton
                                color="inherit"
                                aria-label="open drawer"
                                onClick={() => this.handleDrawerOpen()}
                                edge="start"
                                className={clsx(classes.menuButton, {
                                    [classes.hide]: open
                                })}>
                                <MenuIcon />
                            </IconButton>
                            <Typography variant="h6" noWrap>
                                BlueBubbles App
                            </Typography>
                            <section className={classes.grow} />
                            <IconButton
                                color="inherit"
                                aria-label={`show ${alerts.length} alerts`}
                                aria-controls='alert-menu'
                                aria-haspopup="true"
                                onClick={this.handleAlertOpen}>
                                    <Badge
                                        badgeContent={alerts.filter((item) => !item.isRead).length}
                                        color="secondary">
                                            <NotificationsIcon />
                                    </Badge>
                            </IconButton>
                        </Toolbar>
                    </AppBar>
                    <Drawer
                        variant="permanent"
                        className={clsx(classes.drawer, {
                            [classes.drawerOpen]: open,
                            [classes.drawerClose]: !open
                        })}
                        classes={{
                            paper: clsx({
                                [classes.drawerOpen]: open,
                                [classes.drawerClose]: !open
                            })
                        }}>
                        <div className={classes.toolbar}>
                            <IconButton
                                onClick={() => this.handleDrawerClose()}>
                                <ChevronLeftIcon />
                            </IconButton>
                        </div>
                        <Divider />
                        <List>
                            <ListItem
                                component={Link}
                                to="/"
                                button
                                className={clsx(classes.drawer, {
                                    [classes.listItemOpen]: open,
                                    [classes.listItemClosed]: !open
                                })}>
                                <ListItemIcon>
                                    <HomeIcon />
                                </ListItemIcon>
                                <ListItemText primary="Welcome" />
                            </ListItem>
                            <ListItem
                                component={Link}
                                to="/devices"
                                button
                                className={clsx(classes.drawer, {
                                    [classes.listItemOpen]: open,
                                    [classes.listItemClosed]: !open
                                })}>
                                <ListItemIcon>
                                    <DeviceIcon />
                                </ListItemIcon>
                                <ListItemText primary="Devices" />
                            </ListItem>
                        </List>
                        <Divider />
                        <List>
                            <ListItem
                                component={Link}
                                to="/logs"
                                button
                                className={clsx(classes.drawer, {
                                    [classes.listItemOpen]: open,
                                    [classes.listItemClosed]: !open
                                })}>
                                <ListItemIcon>
                                    <LogIcon />
                                </ListItemIcon>
                                <ListItemText primary="Server Logs" />
                            </ListItem>
                            <ListItem
                                component={Link}
                                to="/configuration"
                                button
                                className={clsx(classes.drawer, {
                                    [classes.listItemOpen]: open,
                                    [classes.listItemClosed]: !open
                                })}>
                                <ListItemIcon>
                                    <SettingsIcon />
                                </ListItemIcon>
                                <ListItemText primary="Configuration" />
                            </ListItem>
                        </List>
                    </Drawer>
                    <section className={classes.container}>
                        <Switch>
                            <Route path="/tutorial">
                                <Tutorial config={config} />
                            </Route>
                            <Route path="/configuration">
                                <Configuration config={config} />
                            </Route>
                            <Route path="/devices">
                                <Devices />
                            </Route>
                            <Route path="/logs">
                                <Logs />
                            </Route>
                            <Route path="/">
                                <Dashboard config={config} />
                            </Route>
                        </Switch>
                    </section>
                </section>
                {this.renderAlerts()}
            </MuiThemeProvider>
        );
    }
}

const drawerWidth = 240;
const styles = (theme: Theme): StyleRules<string, {}> =>
    createStyles({
        grow: {
            flexGrow: 1,
        },
        root: {
            display: "flex"
        },
        appBar: {
            zIndex: theme.zIndex.drawer + 1,
            transition: theme.transitions.create(["width", "margin"], {
                easing: theme.transitions.easing.sharp,
                duration: theme.transitions.duration.leavingScreen
            })
        },
        appBarShift: {
            marginLeft: drawerWidth,
            width: `calc(100% - ${drawerWidth}px)`,
            transition: theme.transitions.create(["width", "margin"], {
                easing: theme.transitions.easing.sharp,
                duration: theme.transitions.duration.enteringScreen
            })
        },
        menuButton: {
            marginRight: 36
        },
        hide: {
            display: "none"
        },
        drawer: {
            width: drawerWidth,
            flexShrink: 0,
            whiteSpace: "nowrap"
        },
        drawerOpen: {
            width: drawerWidth,
            transition: theme.transitions.create("width", {
                easing: theme.transitions.easing.sharp,
                duration: theme.transitions.duration.enteringScreen
            })
        },
        drawerClose: {
            transition: theme.transitions.create("width", {
                easing: theme.transitions.easing.sharp,
                duration: theme.transitions.duration.leavingScreen
            }),
            overflowX: "hidden",
            width: theme.spacing(7) + 1,
            [theme.breakpoints.up("sm")]: {
                width: theme.spacing(9) + 1
            }
        },
        toolbar: {
            display: "flex",
            alignItems: "center",
            justifyContent: "flex-end",
            padding: theme.spacing(0, 1),
            // necessary for content to be below app bar
            ...theme.mixins.toolbar
        },
        listItemClosed: {
            paddingLeft: "25px",
            [theme.breakpoints.down("xs")]: {
                paddingLeft: "16px"
            }
        },
        listItemOpen: {
            paddingLeft: "16px"
        },
        content: {
            flexGrow: 1,
            padding: theme.spacing(3)
        },
        container: {
            width: "100%",
            height: "100%",
            marginTop: "6em",
            marginLeft: "2em",
            marginRight: "2em"
        },
        alertBlock: {
            display: 'flex',
            flexDirection: 'column',
            width: '100%'
        },
        alertBody: {
            width: '100%',
            display: 'flex',
            flexDirection: 'row',
            alignItems: 'flex-start',
            justifyContent: 'space-between'
        },
        alertFooter: {
            marginTop: '10px',
            width: '100%',
            display: 'flex',
            flexDirection: 'row',
            alignItems: 'flex-end',
            justifyContent: 'space-between',
            fontSize: "14px",
            color: "lightgrey"
        }
    });

export default withStyles(styles)(AdminLayout);
