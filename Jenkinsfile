// Publishes the scripts in ci/publish.map to gs://appcircle-prod-common/self-hosted/
// (https://cdn.appcircle.io/self-hosted/) on a push to main (PL-582).
// Every other branch and every pull request runs only the checks; the credential is used only on main.
pipeline {
    agent { label 'agent' }

    options {
        disableConcurrentBuilds()
        timeout(time: 30, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30'))
    }

    environment {
        BUCKET_PATH = 'gs://appcircle-prod-common/self-hosted'
        ORIGIN_URL = 'https://storage.googleapis.com/appcircle-prod-common/self-hosted'
        PUBLIC_URL = 'https://cdn.appcircle.io/self-hosted'
        CACHE_BUST = "${env.BUILD_TAG}"
    }

    stages {
        stage('Syntax') {
            steps {
                sh '''#!/bin/bash
                set -euo pipefail
                for f in *.sh ci/*.sh tests/*.sh; do bash -n "$f"; done
                '''
            }
        }

        stage('ShellCheck') {
            steps {
                sh '''#!/bin/bash
                set -euo pipefail
                docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:stable \
                    --severity=error *.sh ci/*.sh
                '''
            }
        }

        stage('Tests') {
            steps {
                sh '''#!/bin/bash
                set -euo pipefail
                # The tests use the macOS md5 command; map it to md5sum on the Linux agent.
                shimDir="$(mktemp -d)"
                printf '#!/bin/sh\\n[ "$1" = "-q" ] && shift\\nmd5sum "$1" | cut -d " " -f 1\\n' >"$shimDir/md5"
                chmod +x "$shimDir/md5"
                export PATH="$shimDir:$PATH"
                # shunit2 needs a TMPDIR on a partition that allows exec.
                export TMPDIR="$WORKSPACE/.tmp"
                mkdir -p "$TMPDIR"
                ./tests/download-runner-mirror-tests.sh
                ./tests/download-server-tests.sh
                '''
            }
        }

        stage('Build') {
            steps {
                sh 'bash ci/publish.sh build'
            }
        }

        stage('Publish') {
            when {
                allOf {
                    branch 'main'
                    not { changeRequest() }
                }
            }
            steps {
                withCredentials([file(credentialsId: 'PipelineGcloudCredentials', variable: 'gcloudPipelineAccountFile')]) {
                    sh '''#!/bin/bash
                    set -euo pipefail
                    export CLOUDSDK_CONFIG="$WORKSPACE/.gcloud"
                    gcloud auth activate-service-account --key-file="$gcloudPipelineAccountFile"
                    bash ci/publish.sh upload
                    '''
                }
            }
        }

        stage('Verify') {
            when {
                allOf {
                    branch 'main'
                    not { changeRequest() }
                }
            }
            steps {
                sh 'bash ci/publish.sh verify'
            }
        }
    }

    post {
        always {
            sh 'rm -rf "$WORKSPACE/.gcloud" "$WORKSPACE/.tmp"'
        }
    }
}
