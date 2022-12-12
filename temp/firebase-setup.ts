const express = require("express")
const app = express()

// Express stuff is safe to remove, used it for testing

const {google} = require("googleapis")

import axios from "axios"
import { googleClientSecret } from "./keys/keys";
import { googleClientID } from "./keys/keys";

const googleOauthRedirectURL: string = "http://localhost:3000/api/login/google"

const oauth2Client = new google.auth.OAuth2(
     googleClientID,
     googleClientSecret,
     googleOauthRedirectURL
);




let projectName: string, token: string // Define in a global scope

app.get("/", async (req: any, res: any) => res.send(`<a href=${await generateAuthUrl()}>Sign in with Google</a>`))
app.get("/api/login/google", async (req: any, res: any) => {

    const code = req.query.code
    const tokensJSON = await oauth2Client.getToken(code)
    token = tokensJSON.tokens.access_token

    console.log("token: " + token) // For testing with reqbin, should be removed

    projectName = "bluebubblestest43" //  Must be 6 to 30 lowercase letters, digits, or hyphens. It must start with a letter. Trailing hyphens are prohibited.

    
    await createGoogleCloudProject()
    console.log("gcp done")

    await enableFirestoreApi()
    console.log("enable firestore done")

    await createFirebase()
    console.log("create firebase done")

    await createDatabase()
    console.log("create db done")

    await createAndroidApp()
    console.log("android done")

    const privKey = await getPrivateKey()
    const gJson = await getGoogleServicesJson()



    res.send(`<br><br><a href=${await generateAuthUrl()}>Sign in with Google</a><br><br><br>${privKey}<br><br><br>${gJson}`)



})


app.listen(3000, () => console.log('\n\n\n\n\n\n\nListening..'))

// GOOGLE STUFF

async function generateAuthUrl() {

    const scopes = [
        "https://www.googleapis.com/auth/cloud-platform"
      ];

    const url = await oauth2Client.generateAuthUrl({
        access_type: 'offline',
        scope: scopes
      });

    return url
}

function waitUntilOperationDone(operation: string, isGcp?: boolean){

    return new Promise((resolve) => {

        const interval = setInterval(async () => {


                const url = (isGcp) ? `https://cloudresourcemanager.googleapis.com/v1/${operation}` : `https://firebase.googleapis.com/v1beta1/${operation}`
                const response = await sendGetRequest(url)

                if (response.data.done) {
                    clearInterval(interval)
                    resolve(true)
                }

        }, 2000)
    })
}

async function sendGetRequest(url: string) {

    const headers = {
        'Authorization': 'Bearer ' + token,
        'Content-Type': 'application/json'
    }

    const response = await axios.get(url, {headers})

    return response
}

async function sendPostRequest(url: string, data?: object) {

    const headers = {
        'Authorization': 'Bearer ' + token,
        'Content-Type': 'application/json'
    }

    data = (data) ? data : {}

    const response = await axios.post(url, data, {headers}).then(response => {return response})

    return response
}

async function createGoogleCloudProject() {

    let url = "https://cloudresourcemanager.googleapis.com/v1/projects"
    const data = {"name": `${projectName}`,"projectId": `${projectName}`}

    let response = await sendPostRequest(url, data)

    // Wait until project is created before returning

    await waitUntilOperationDone(response.data.name, true)

    return
}

async function createFirebase() {
    let url = `https://firebase.googleapis.com/v1beta1/projects/${projectName}:addFirebase`

    let response = await sendPostRequest(url)

    url = `https://firebase.googleapis.com/v1beta1/${response.data.name}`
    response = await sendGetRequest(url)

    await waitUntilOperationDone(response.data.name)

    return
}

async function enableFirestoreApi() {

    // Get project number
    let url = `https://cloudresourcemanager.googleapis.com/v1/projects/${projectName}`

    let response: any = await sendGetRequest(url)

    const projectNumber = response.data.projectNumber

    url = `https://serviceusage.googleapis.com/v1/projects/${projectNumber}/services/firestore.googleapis.com:enable`

    response = await sendPostRequest(url)

    return response
}

async function createDatabase() {
    const url = `https://firestore.googleapis.com/v1/projects/${projectName}/databases?databaseId=(default)`

    const data = {"type": "FIRESTORE_NATIVE", "locationId" : "nam5"}

    const response = await sendPostRequest(url, data)

    return response.data.name
}
/* createRealtimeDatabase, paywalled API :/
async function createRealtimeDatabase() {
    const url = `https://firebasedatabase.googleapis.com/v1beta/projects/${projectName}/locations/us-central1/instances?databaseId=${projectName}&validateOnly=false`
    const data = {"name": projectName}

    return await sendPostRequest(url, data)
} */

async function getFirebaseServiceAccountId(): Promise<string> {
    const url = `https://iam.googleapis.com/v1/projects/${projectName}/serviceAccounts`

    // Wait until the account is there

    await new Promise((resolve) => {

        const interval = setInterval(async () => {

            const res = await sendGetRequest(url)
                if (res.data.accounts) {
                clearInterval(interval)
                resolve(true)
            }

        }, 2000)
    })

    // Parse request to find the uniqueId of the Firebase Service Account

    const response: any = await sendGetRequest(url)

    console.log("RESPONSE: " + response.data)

    const firebaseServiceAccounts = response.data.accounts

    const isFirebaseServiceAccount = (element: any) => element.name.includes("firebase-adminsdk");
    const firebaseServiceAccountID: any = firebaseServiceAccounts.find(isFirebaseServiceAccount).uniqueId

    return firebaseServiceAccountID
}

async function getPrivateKey() {

    const firebaseServiceAccountId: string = await getFirebaseServiceAccountId()

    const url = `https://iam.googleapis.com/v1/projects/${projectName}/serviceAccounts/${firebaseServiceAccountId}/keys`

    const response: any = await sendPostRequest(url)

    const b64Key = response.data.privateKeyData

    const privateKeyData = Buffer.from((b64Key), 'base64').toString('utf-8')

    return privateKeyData
}

async function createAndroidApp() {

    let url = `https://firebase.googleapis.com/v1beta1/projects/${projectName}/androidApps`
    const data = {"packageName": `com.${projectName}.bluebubbles`}

    let response = await sendPostRequest(url, data)

    // Wait until app is created before returning

    await waitUntilOperationDone(response.data.name)

    return
}

async function getGoogleServicesJson() {

    let url = `https://firebase.googleapis.com/v1beta1/projects/${projectName}/androidApps`

    let response: any = await sendGetRequest(url)

    const appId = response.data.apps[0].appId // There should only be one app, the one we created

    url = `https://firebase.googleapis.com/v1beta1/projects/${projectName}/androidApps/${appId}/config`

    response = await sendGetRequest(url)

    const b64Config = response.data.configFileContents

    const config = Buffer.from((b64Config), 'base64').toString('utf-8')

    return config
}

