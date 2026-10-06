"""Refresh XNAT alias credentials and roll the per-edge upload Deployments."""
import base64
import datetime
import json
import os
import ssl
import urllib.request


def main():
    source = os.environ["XNAT_SOURCE_SERVER"].rstrip("/")
    authorization = base64.b64encode((os.environ["XNAT_SOURCE_USER"] + ":" + os.environ["XNAT_SOURCE_PASS"]).encode()).decode()
    request = urllib.request.Request(source + "/data/services/tokens/issue?format=json")
    request.add_header("Authorization", "Basic " + authorization)
    context = ssl.create_default_context() if os.environ["XNAT_VERIFY_SSL"] == "true" else ssl._create_unverified_context()
    with urllib.request.urlopen(request, timeout=30, context=context) as response:
        issued = json.load(response)
    stamp = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    with open("/var/run/secrets/kubernetes.io/serviceaccount/token") as handle:
        bearer = handle.read().strip()
    kube_context = ssl.create_default_context(cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
    namespace = os.environ["POD_NAMESPACE"]

    def patch(path, body):
        req = urllib.request.Request("https://kubernetes.default.svc" + path,
                                     data=json.dumps(body).encode(), method="PATCH")
        req.add_header("Authorization", "Bearer " + bearer)
        req.add_header("Content-Type", "application/merge-patch+json")
        with urllib.request.urlopen(req, timeout=30, context=kube_context) as response:
            response.read()

    data = {"server": os.environ.get("XNAT_UPLOAD_SERVER") or source,
            "username": issued["alias"], "password": issued["secret"]}
    annotations = {"ais-edge/xnat-token-refreshed-at": stamp,
                   "ais-edge/xnat-token-expires": str(issued.get("estimatedExpirationTime", "unknown"))}
    patch(f"/api/v1/namespaces/{namespace}/secrets/" + os.environ["XNAT_TARGET_SECRET"],
          {"metadata": {"annotations": annotations},
           "data": {key: base64.b64encode(value.encode()).decode() for key, value in data.items()}})
    for deployment in json.loads(os.environ["UPLOAD_DEPLOYMENTS"]):
        patch(f"/apis/apps/v1/namespaces/{namespace}/deployments/{deployment}",
              {"spec": {"template": {"metadata": {"annotations": annotations}}}})
    print("refreshed XNAT alias credentials at " + stamp)


if __name__ == "__main__":
    main()
