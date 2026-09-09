import * as Dialog from '@radix-ui/react-dialog';
import { X } from 'lucide-react';
import { WorkspaceInvitations, type WorkspaceInvitationsProps } from './WorkspaceInvitations';

export function WorkspaceInvitationDialog({ open, onOpenChange, ...props }: WorkspaceInvitationsProps & { open: boolean; onOpenChange: (open: boolean) => void }) {
  return <Dialog.Root open={open} onOpenChange={onOpenChange}><Dialog.Portal><Dialog.Overlay className="dialog-overlay" /><Dialog.Content className="dialog-content wi-dialog">
    <header className="wi-dialog-header"><Dialog.Title>{props.mode === 'join' ? '加入工作空间' : '邀请同事'}</Dialog.Title><Dialog.Close className="icon-button" aria-label="关闭邀请窗口"><X size={20} /></Dialog.Close><Dialog.Description>邀请只授予普通成员身份，并按当前工作身份核对操作。</Dialog.Description></header>
    <div className="wi-dialog-body"><WorkspaceInvitations {...props} embedded /></div>
    <footer className="wi-dialog-footer"><Dialog.Close className="secondary">关闭</Dialog.Close></footer>
  </Dialog.Content></Dialog.Portal></Dialog.Root>;
}
