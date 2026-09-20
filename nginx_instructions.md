                                                                                                        
  Steps to deploy                                                                                        
  1. DNS: add an A record for jenkins.boljao.com pointing to 49.13.60.243. If you use IPv6, add an AAAA  
     record for 2a01:4f8:c014:1451::1. Check it with dig +short jenkins.boljao.com.                      
  2. Jenkins: copy the updated jenkins_install.sh to the server and run it.                              
  3. nginx: add the new block to your server's nginx config, then run:                                   
  `sudo nginx -t && sudo systemctl reload nginx`                                                           
  `sudo certbot --nginx -d jenkins.boljao.com`                                                             
     Certbot adds the 443 listener, the certificate, and the HTTP-to-HTTPS redirect to that block. If    
     you're managing the file from this repo, copy the result back afterwards.                           
  4. Jenkins URL: in Jenkins, go to Manage Jenkins, then System, and set Jenkins URL to                  
     https://jenkins.boljao.com/. This avoids the reverse-proxy warning.                                 
                                                                                                         
  Port 443 works today, so a Hetzner firewall that allows only 22, 80 and 443 won't get in the way.      
  Certbot also needs port 80 open, which it already is.                                                  
                                                                                                         
  Two things to know:                                                                                    
  - The new block relies on your server's nginx including this file in the http context, as your existing
    blocks do.                                                                                           
  - Port 50000, used by inbound Jenkins agents, is still published on all interfaces. It's harmless while
    the firewall blocks it. If you never use remote agents, I can bind it to 127.0.0.1 too.              
  