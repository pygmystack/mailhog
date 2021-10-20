# the pygmy stack - MailHog image

This image is a multiarchitecture compatible docker image

It is based on https://github.com/mailhog/MailHog with the following modifications:
- the go version for building MailHog has been updated to go 1.16
- the dockerfile build process has been moved to GitHub actions to enable multiarch