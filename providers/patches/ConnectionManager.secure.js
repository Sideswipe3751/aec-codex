import { RevitClientConnection } from "./SocketClient.js";

let connectionMutex = Promise.resolve();

export async function withRevitConnection(operation) {
    const previousMutex = connectionMutex;
    let releaseMutex;
    connectionMutex = new Promise((resolve) => {
        releaseMutex = resolve;
    });
    await previousMutex;
    const revitClient = new RevitClientConnection("127.0.0.1", 8080);
    try {
        if (!revitClient.isConnected) {
            await new Promise((resolve, reject) => {
                let timer;
                const cleanup = () => {
                    clearTimeout(timer);
                    revitClient.socket.removeListener("connect", onConnect);
                    revitClient.socket.removeListener("error", onError);
                };
                const onConnect = () => {
                    cleanup();
                    resolve();
                };
                const onError = () => {
                    cleanup();
                    reject(new Error("connect to Revit provider failed"));
                };
                revitClient.socket.on("connect", onConnect);
                revitClient.socket.on("error", onError);
                revitClient.connect();
                timer = setTimeout(() => {
                    cleanup();
                    reject(new Error("connect to Revit provider timed out"));
                }, 5000);
            });
        }
        return await operation(revitClient);
    } finally {
        revitClient.disconnect();
        releaseMutex();
    }
}
