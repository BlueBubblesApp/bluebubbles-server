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

// Material UI Icons
import MenuIcon from "@material-ui/icons/Menu";
import ChevronLeftIcon from "@material-ui/icons/ChevronLeft";
import DeviceIcon from "@material-ui/icons/DeviceHub";
import HomeIcon from "@material-ui/icons/Home";
import SettingsIcon from "@material-ui/icons/Settings";

// Custom Components
import Configuration from "@renderer/views/Configuration";
import Devices from "@renderer/views/Devices";
import Dashboard from "@renderer/views/Dashboard";

// Helpers
import { Config } from "@renderer/variables/types";

const CustomMuiTheme = createMuiTheme({
    palette: {
        type: "dark"
    }
});

interface Props {
    classes: any;
}

interface State {
    open: boolean
    config: Config
}

class AdminLayout extends React.Component<Props, State> {
    state: State = {
        open: false,
        config: null
    }

    componentDidMount() {
        ipcRenderer.on("config-update", (event, arg) => {
            console.log(arg)
            this.setState({
                config: arg
            })
        })
    }

    handleDrawerOpen = () => {
        this.setState({ open: true });
    };

    handleDrawerClose = () => {
;        this.setState({ open: false });
    };

    render() {
        const { classes } = this.props;
        const { open, config } = this.state;

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
                                BlueBubble App
                            </Typography>
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
                            <Route path="/configuration">
                                <Configuration config={config} />
                            </Route>
                            <Route path="/devices">
                                <Devices />
                            </Route>
                            <Route path="/">
                                <Dashboard />
                            </Route>
                        </Switch>
                    </section>
                </section>
            </MuiThemeProvider>
        );
    }
}

const drawerWidth = 240;
const styles = (theme: Theme): StyleRules<string, {}> =>
    createStyles({
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
        }
    });

export default withStyles(styles)(AdminLayout);
