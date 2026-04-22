# Decription
This is a shell script for managing a bare xray installation on your VPS server. No web panels are used here (except a fake one). The script allows you to manage:
- the core;
- users;
- HTTPS subscriptions without panels;
- generating vless and HTTPS links and QR codes for clients;
- automatically setting up the infrastructure for you with the following config: xray + vless + reality + selfsteal, nginx + subscriptions + fake web page;

To use any of that sh scripts:
- `git clone` this repo
- `cd xray-reality-selfsteal` to go to repo directory
- `sudo chmod +x *` to make all the files executable
- `./`

## Options
1. Core management
    1. Start | Stop | Restart
    2. Edit config in nvim
    3. Create config backup
    4. Restore from backup
2. User & Subscription Management
    1. List users & subscriptions
    2. Link & QR code generation
    3. Create | delete users
    4. Create | delete subscription
    5. Add | remove user from subscription
    6. Edit subscription in nvim

# Autodeploy
After you launch that point, the script will ask you to enter your domain, after that it will begin the deployr sequence:
1) Download & install all the dependencies
2) Generate xray config (vless + reality + selfsteal)
3) Generate fake web page (confluence like, that web page will be accessible with 443 port, which is listened by xray)
4) Generate nginx config for fake web page & subscriptions(via security path)
5) Deploys it all to the working state
6) Then you will be able to create users and maintain them

# Dual-server 2hop + routing
In case if you deside to create 2hop system (you connect to server 1, it makes domain routing and or send direct queries or routes the traffick to the server 2), there is:
1. Manual how to do that
2. List of domains for ru zone that you'd better send to direct via routing rules in xray config

