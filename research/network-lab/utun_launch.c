/* Disposable hosted macOS only. Opens a real utun; never changes a default route. */
#include <sys/socket.h>
#include <sys/kern_control.h>
#include <sys/ioctl.h>
#include <sys/sys_domain.h>
#include <net/if.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc,char **argv){
 if(argc!=3 || geteuid()!=0 || !getenv("GITHUB_ACTIONS") || strcmp(getenv("GITHUB_ACTIONS"),"true") || !getenv("CS_REAL_UTUN_LAB") || strcmp(getenv("CS_REAL_UTUN_LAB"),"ephemeral-only"))return 2;
 int fd=socket(PF_SYSTEM,SOCK_DGRAM,SYSPROTO_CONTROL);if(fd<0){perror("socket");return 3;}
 struct ctl_info info;memset(&info,0,sizeof(info));strncpy(info.ctl_name,"com.apple.net.utun_control",sizeof(info.ctl_name)-1);
 if(ioctl(fd,CTLIOCGINFO,&info)<0){perror("ioctl");return 4;}
 struct sockaddr_ctl sc;memset(&sc,0,sizeof(sc));sc.sc_len=sizeof(sc);sc.sc_family=AF_SYSTEM;sc.ss_sysaddr=AF_SYS_CONTROL;sc.sc_id=info.ctl_id;
 if(connect(fd,(struct sockaddr*)&sc,sizeof(sc))<0){perror("connect");return 5;}
 char name[IFNAMSIZ];socklen_t n=sizeof(name);if(getsockopt(fd,SYSPROTO_CONTROL,2,name,&n)<0){perror("ifname");return 6;}
 fcntl(fd,F_SETFD,0);char number[32];snprintf(number,sizeof(number),"%d",fd);
 execl(argv[1],argv[1],argv[2],name,number,(char*)NULL);perror("exec");return 7;
}
