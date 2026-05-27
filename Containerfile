# Runner image: ansible-core + kubernetes.core + OpenShift CLI.
# Mirrors the containerized-execution model of regional-dr-example so no
# local ansible toolchain is required on the operator workstation.
FROM registry.access.redhat.com/ubi9/python-312:latest

USER 0

ARG OC_VERSION=stable
RUN curl -sSL \
      "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OC_VERSION}/openshift-client-linux.tar.gz" \
      -o /tmp/oc.tgz \
 && tar -xzf /tmp/oc.tgz -C /usr/local/bin oc kubectl \
 && rm -f /tmp/oc.tgz \
 && chmod +x /usr/local/bin/oc /usr/local/bin/kubectl

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt \
 && ansible-galaxy collection install kubernetes.core community.general \
 && chown -R 1001:0 /opt/app-root/src/.ansible \
 && chmod -R g+rwX /opt/app-root/src/.ansible

USER 1001
WORKDIR /work
ENTRYPOINT []
CMD ["ansible-playbook", "--version"]
