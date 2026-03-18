FROM axllent/mailpit:v1.29

ENV MP_UI_BIND_ADDR=[::]:80

RUN ln -s /mailpit /bin/MailHog

ENTRYPOINT ["/mailpit"]
