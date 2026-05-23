// port.js

async function getListeningPort() {
  fetch("/api/backend-port").then(
    res => res.json()
  ).then(data => {
      document.getElementById("port").innerText = data.port;
  }).catch(
    error => console.error("Error:". error)
  );
}

getListeningPort();
