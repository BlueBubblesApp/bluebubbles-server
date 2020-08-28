/* eslint-disable react/prefer-stateless-function */
import * as React from "react";
import Dropzone from 'react-dropzone'
const { shell } = window.require('electron');

import "./PreDashboardView.css";

class PreDashboardView extends React.Component {
    render() {
        return (
            <div id="PreDashboardView">
                <div id="welcomeOverlay">
                    <h1>Welcome</h1>
                </div>
                <div id="predashboardContainer">
                    <p id="introText">Thank you downloading BlueBubbles! In order to get started, follow the instructions outlined in <a style={{color: "#147EFB"}} href="https://www.bluebubbles.app/install.html">our installation tutorial</a></p>
                    <div id="permissionStatusContainer">
                        <h1>Required App Permissions</h1>
                            <div className="permissionTitleContainer">
                                <h3 className="permissionTitle">Full Disk Access:</h3>
                                <h3 className="permissionStatus granted">Enabled</h3>
                            </div>
                            <div className="permissionTitleContainer">
                                <h3 className="permissionTitle">Full Accessibility Access:</h3>
                                <h3 className="permissionStatus denied">Disabled</h3>
                            </div>                            
                    </div>
                    <h1 id="uploadTitle">Required Config Files</h1>
                    <Dropzone onDrop={acceptedFiles => console.log(acceptedFiles)}>
                        {({getRootProps, getInputProps}) => (
                            <section id="fcmClientDrop">
                            <div {...getRootProps()}>
                                <input {...getInputProps()} />
                                <p>Drag or click to upload FCM Server</p>
                            </div>
                            </section>
                        )}
                    </Dropzone>
                    <Dropzone onDrop={acceptedFiles => console.log(acceptedFiles)}>
                        {({getRootProps, getInputProps}) => (
                            <section id="fcmServerDrop">
                            <div {...getRootProps()}>
                                <input {...getInputProps()} />
                                <p>Drag or click to upload FCM Client (google-services.json)</p>
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
