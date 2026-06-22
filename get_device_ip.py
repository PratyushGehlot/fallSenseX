import json  
import urllib.request  
  
def get_device_ip(url, device=\"FallSense_X1\"):  
    \"try to get IP from Firebase\"  
    try:  
        req=urllib.request.Request(f\"{url}/devices/{device}/info.json\")  
        with urllib.request.urlopen(req,timeout=5) as r:  
            d=json.loads(r.read().decode())  
            if d and d.get(\"ip_address\"):  
                print(f\"Device: {d.get('device_id')}\")  
                print(f\"IP: {d['ip_address']}:{d.get('port','3333')}\")  
                return d['ip_address']  
            else: print(\"No device info\")  
    except Exception as e: print(f\"Error: {e}\")  
  
if __name__==\"__main__\":  
    u=input(\"Firebase URL: \").strip() or \"https://chakshufallsense-default-rtdb.firebaseio.com\"  
    ip=get_device_ip(u)  
    if ip: print(f\"\\nConnect: telnet {ip} 3333\") 
