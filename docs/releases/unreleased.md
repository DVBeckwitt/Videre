# Next Videre update

## Find media companion hosts

A media companion is a server your Invidious instance may use to deliver
video or audio. Your chosen instance still handles search, comments, and your
account. If it sends playback to a different HTTPS address, Videre needs your
approval before it can stream from that address. If playback already works,
you can leave the list empty.

Open **Settings → Manage servers**, select the instance account, and choose
**Find media hosts** under **Media companion hosts**. Videre checks one sample
video and shows the exact addresses it finds for you to review. Other videos
may use different addresses. Ask your instance operator for the public HTTPS address
if you need to enter one manually. For example, enter
`https://media.example.org:8443` if they give you
`https://media.example.org:8443/companion`.

Videre remembers approvals for that instance within your profile. An approved
host can see the stream request and the IP address used to connect to it.
Your sign-in credentials stay with your Invidious instance.
[Media companion guide](https://github.com/DVBeckwitt/Videre/blob/master/README.md#media-companion-hosts)

## Other changes

- Ordinary HTTPS NerdVPN accounts have a dedicated **Sign in to NerdVPN**
  action. Sign-in errors explain connection failures, rate limits, and
  temporary server outages. When NerdVPN sets a retry time, Videre shows it
  and waits before opening sign-in again.
- **Settings → About → Release notes** opens the notes for your installed
  version and lets you read older releases offline. Open a link in the notes
  to see its address and copy it.
